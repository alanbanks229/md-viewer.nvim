// The control socket: how the remote plugin reaches the helper.
//
// One unix-domain listener on the operator's machine -- 0600 in a 0700 dir,
// never TCP (`tests/node/local-no-listening-port.test.js` holds that line) --
// reached from the VM through the `ssh -R` forward the helper adds to its own
// ssh invocation. sshd creates the remote endpoint 0600 under its default
// StreamLocalBindMask (measured 2026-08-26 against a real forward; the
// plugin still verifies rather than trusts).
//
// Framing is the same NDJSON as the stdio renderer protocol: `{id, method,
// params}` up, `{id, ok, result|error, code, detail}` down, plus id-less
// `{event, ...}` notification lines the stdio protocol never needed
// (`presented`, `missing`, `stats` -- the async half of the replicated
// design). The first request on a connection must be `hello`, and the hello
// is where version skew dies: two independently updated checkouts meet here,
// so the handshake carries protocol and versions both ways and refuses a
// mismatch outright.
//
// One client at a time, refused not queued: the service fronts one browser,
// one page, and one serial queue (service.js's own stated limit), and a
// second nvim silently sharing a document cache with the first would be a
// correctness bug wearing a convenience feature's clothes.

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { LOCAL_PROTOCOL } from "./version.js";

// sun_path is ~104 bytes on macOS (108 on Linux); a listen() on anything
// longer fails with EINVAL. Guarded here with the fix in the message because
// the failure mode -- a deep $HOME -- is otherwise a one-line kernel errno.
const SOCKET_PATH_MAX = 100;

export function defaultSocketDir() {
  return path.join(os.homedir(), ".local", "state", "md-viewer", "local");
}

export class SocketService {
  constructor({ token, helperVersion, probe, dir = defaultSocketDir() } = {}) {
    this.token = token;
    this.helperVersion = helperVersion;
    this.probe = probe ?? null;
    this.dir = dir;
    this.socketPath = path.join(this.dir, `${process.pid}-${token.slice(0, 6)}.sock`);
    this.server = null;
    this.client = null; // the one authenticated connection
    this.requestHandler = null; // (method, params) -> Promise<result>, wired by the session layer
    this.onClientChange = () => {};
    this.stats = { helloCount: 0, refusedBusy: 0, refusedProtocol: 0, requests: 0, notifications: 0 };
  }

  /// Later commits hand the replica renderer's dispatch in through this; until
  /// then every post-hello method is answered UNSUPPORTED_METHOD rather than
  /// hanging or guessing.
  setRequestHandler(handler) {
    this.requestHandler = handler;
  }

  listen() {
    if (Buffer.byteLength(this.socketPath) > SOCKET_PATH_MAX) {
      throw new Error(
        `md-viewer-local: socket path exceeds the unix sun_path limit (${this.socketPath}); ` +
          `set a shorter state directory`
      );
    }
    fs.mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    fs.chmodSync(this.dir, 0o700); // mkdir's mode is masked by umask; force it
    try {
      fs.unlinkSync(this.socketPath);
    } catch {}
    this.server = net.createServer((socket) => this.accept(socket));
    return new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(this.socketPath, () => {
        fs.chmodSync(this.socketPath, 0o600);
        resolve(this.socketPath);
      });
    });
  }

  accept(socket) {
    if (this.client !== null) {
      this.stats.refusedBusy += 1;
      socket.write(
        `${JSON.stringify({ id: -1, ok: false, code: "BUSY", error: "md-viewer-local already serves one session; a second nvim cannot share the replica" })}\n`
      );
      socket.end();
      return;
    }

    const connection = { socket, buffer: "", helloDone: false };
    this.client = connection;
    socket.setNoDelay?.(true);

    const drop = () => {
      if (this.client === connection) {
        this.client = null;
        this.onClientChange(false);
      }
      socket.destroy();
    };
    socket.on("error", drop);
    socket.on("close", drop);

    // A connection that never says hello is a scanner or a bug; either way it
    // does not get to hold the one client slot.
    const helloTimer = setTimeout(() => {
      if (!connection.helloDone) drop();
    }, 5000);
    helloTimer.unref();

    socket.on("data", (chunk) => {
      connection.buffer += chunk.toString("utf8");
      let newline;
      while ((newline = connection.buffer.indexOf("\n")) !== -1) {
        const line = connection.buffer.slice(0, newline);
        connection.buffer = connection.buffer.slice(newline + 1);
        this.handleLine(connection, line, drop, helloTimer);
      }
      // NDJSON lines are bounded small (assets travel base64 inside one
      // line, capped by the sender); a "line" that never ends is hostile.
      if (connection.buffer.length > 64 * 1024 * 1024) drop();
    });
  }

  handleLine(connection, line, drop, helloTimer) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.reply(connection, { id: -1, ok: false, code: "INVALID_REQUEST", error: "unparseable request line" });
      return;
    }
    if (!Number.isInteger(message?.id) || typeof message?.method !== "string") {
      this.reply(connection, { id: message?.id ?? -1, ok: false, code: "INVALID_REQUEST", error: "requests need an integer id and a method" });
      return;
    }

    if (!connection.helloDone) {
      if (message.method !== "hello") {
        this.reply(connection, { id: message.id, ok: false, code: "HELLO_REQUIRED", error: "the first request on this socket must be hello" });
        drop();
        return;
      }
      const remote = message.params ?? {};
      this.stats.helloCount += 1;
      if (remote.protocol !== LOCAL_PROTOCOL) {
        this.stats.refusedProtocol += 1;
        this.reply(connection, {
          id: message.id,
          ok: false,
          code: "PROTOCOL_MISMATCH",
          error: `helper speaks local protocol ${LOCAL_PROTOCOL}, plugin sent ${remote.protocol}; update the older checkout to the same md-viewer tag`,
          detail: { helperProtocol: LOCAL_PROTOCOL, helperVersion: this.helperVersion },
        });
        drop();
        return;
      }
      connection.helloDone = true;
      clearTimeout(helloTimer);
      this.onClientChange(true, remote);
      this.reply(connection, {
        id: message.id,
        ok: true,
        result: {
          protocol: LOCAL_PROTOCOL,
          helperVersion: this.helperVersion,
          token: this.token,
          terminal: this.probe
            ? {
                kittyGraphics: this.probe.kittyGraphics,
                cellPixels: this.probe.cellPixels,
                da1: this.probe.da1,
                probeSkipped: this.probe.skipped,
              }
            : null,
        },
      });
      return;
    }

    this.stats.requests += 1;
    const handler = this.requestHandler;
    if (!handler) {
      this.reply(connection, { id: message.id, ok: false, code: "UNSUPPORTED_METHOD", error: `no handler for ${message.method}` });
      return;
    }
    Promise.resolve()
      .then(() => handler(message.method, message.params ?? {}))
      .then((result) => this.reply(connection, { id: message.id, ok: true, result: result ?? {} }))
      .catch((error) =>
        this.reply(connection, {
          id: message.id,
          ok: false,
          error: error?.message ?? String(error),
          code: error?.code ?? "LOCAL_ERROR",
          detail: error?.detail,
        })
      );
  }

  reply(connection, message) {
    if (connection.socket.destroyed) return;
    connection.socket.write(`${JSON.stringify(message)}\n`);
  }

  /// Async, id-less line to the attached plugin: presented / missing / stats.
  notify(event, fields = {}) {
    if (!this.client || !this.client.helloDone || this.client.socket.destroyed) return false;
    this.stats.notifications += 1;
    this.client.socket.write(`${JSON.stringify({ event, ...fields })}\n`);
    return true;
  }

  connected() {
    return this.client !== null && this.client.helloDone;
  }

  close() {
    if (this.client) {
      this.client.socket.destroy();
      this.client = null;
    }
    if (this.server) {
      this.server.close();
      this.server = null;
    }
    try {
      fs.unlinkSync(this.socketPath);
    } catch {}
  }
}
