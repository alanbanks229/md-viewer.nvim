// The companion entrypoint: same renderer, reached over a unix socket.
//
// The claims worth pinning here are the ones that narrow a documented promise.
// "The renderer opens no listening port" becomes "no *TCP* port, and the client
// socket is a 0600 filesystem object" -- so both halves are asserted against a
// real running companion rather than read off the source. The rest is the
// behaviour a long-lived server needs and a child process never did: stale
// socket recovery, connection takeover, and forgetting a disconnected session's
// documents so the next one does not inherit them under the same buffer ids.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import net from "node:net";
import path from "node:path";
import readline from "node:readline";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { start, defaultSocketPath, parseArgs, clearStaleSocket } from "../../renderer/src/companion.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(here, "../../renderer/assets");

function scratchSocket(label) {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-companion-test-")), `${label}.sock`);
}

/// A minimal NDJSON client, which is all the plugin's Lua side is.
function connect(socketPath) {
  const socket = net.connect(socketPath);
  const pending = new Map();
  let id = 0;
  readline.createInterface({ input: socket }).on("line", (line) => {
    const message = JSON.parse(line);
    const resolve = pending.get(message.id);
    if (resolve) {
      pending.delete(message.id);
      resolve(message);
    }
  });
  return {
    socket,
    ready: new Promise((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    }),
    request(method, params) {
      id += 1;
      const mine = id;
      return new Promise((resolve) => {
        pending.set(mine, resolve);
        socket.write(`${JSON.stringify({ id: mine, method, params })}\n`);
      });
    },
    close() {
      socket.destroy();
    },
  };
}

function listeningTcpPorts() {
  try {
    const out = execFileSync("lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n"], { encoding: "utf8" });
    return new Set(out.split("\n").filter(Boolean));
  } catch (error) {
    if (error.status === 1 && !error.stdout) return new Set();
    throw error;
  }
}

test("the companion serves the renderer protocol over a 0600 unix socket and opens no TCP port", async (t) => {
  const before = listeningTcpPorts();
  const socketPath = scratchSocket("basic");
  const companion = await start({ socketPath, assetsDir });
  t.after(() => companion.stop());

  const stat = fs.statSync(socketPath);
  assert.ok(stat.isSocket(), "the endpoint is a unix socket, not a file");
  // Mode is the whole access control story here: a forwarded port lands on this
  // machine as a local connection, so anything else on the machine could reach
  // a group- or world-accessible socket.
  assert.equal(stat.mode & 0o777, 0o600, `socket mode should be 0600, was ${(stat.mode & 0o777).toString(8)}`);

  const client = connect(socketPath);
  t.after(() => client.close());
  await client.ready;

  const pong = await client.request("ping", {});
  assert.equal(pong.ok, true);
  assert.deepEqual(pong.result, { pong: true });

  // The id echo is what lets the Lua side match a response to its callback, and
  // it is the one protocol property a new transport could plausibly break.
  const first = client.request("ping", {});
  const second = client.request("ping", {});
  const [a, b] = await Promise.all([first, second]);
  assert.notEqual(a.id, b.id, "concurrent requests keep distinct ids");

  const opened = [...listeningTcpPorts()].filter((line) => !before.has(line));
  assert.deepEqual(opened, [], "no listening TCP port appeared while the companion was running");
});

test("shutdown ends the session without stopping the server", async (t) => {
  const socketPath = scratchSocket("shutdown");
  const companion = await start({ socketPath, assetsDir });
  t.after(() => companion.stop());

  const client = connect(socketPath);
  await client.ready;
  const reply = await client.request("shutdown", {});
  assert.deepEqual(reply.result, { shutdown: true }, "the client is told its session ended");
  client.close();

  // A companion that exited here would make every Neovim restart pay a cold
  // Chromium launch, which is the cost it exists to avoid.
  const second = connect(socketPath);
  t.after(() => second.close());
  await second.ready;
  const pong = await second.request("ping", {});
  assert.deepEqual(pong.result, { pong: true }, "the companion still serves after a session shuts down");
});

test("a second connection takes over from the first", async (t) => {
  const socketPath = scratchSocket("takeover");
  const companion = await start({ socketPath, assetsDir });
  t.after(() => companion.stop());

  const first = connect(socketPath);
  await first.ready;
  await first.request("ping", {});
  const dropped = new Promise((resolve) => first.socket.once("close", resolve));

  const second = connect(socketPath);
  t.after(() => second.close());
  await second.ready;
  await dropped;

  const pong = await second.request("ping", {});
  assert.deepEqual(pong.result, { pong: true }, "the newest connection is the one being served");
});

test("a disconnected session's documents are forgotten", async (t) => {
  const socketPath = scratchSocket("forget");
  const companion = await start({ socketPath, assetsDir });
  t.after(() => companion.stop());

  const client = connect(socketPath);
  await client.ready;
  // `capture` with nothing cached is the exact shape of the hazard: it answers
  // from the document cache without re-reading the source, so a stale entry
  // under a reused buffer id would render the previous session's file.
  const miss = await client.request("capture", { documentId: "buffer-7", contentRevision: "1:0" });
  assert.equal(miss.ok, false);
  assert.equal(miss.code, "CAPTURE_CACHE_MISS", "an unrendered document cannot be captured");
  client.close();

  const second = connect(socketPath);
  t.after(() => second.close());
  await second.ready;
  const again = await second.request("capture", { documentId: "buffer-7", contentRevision: "1:0" });
  assert.equal(again.code, "CAPTURE_CACHE_MISS", "the new session starts with an empty document namespace");
});

test("a stale socket is reclaimed and a live one is refused", async (t) => {
  const socketPath = scratchSocket("stale");
  // Debris: a socket file with nothing behind it, which is what a companion
  // killed with SIGKILL leaves.
  const orphan = net.createServer();
  await new Promise((resolve) => orphan.listen(socketPath, resolve));
  await new Promise((resolve) => orphan.close(resolve));
  fs.writeFileSync(socketPath, "");
  assert.equal(await clearStaleSocket(socketPath), "removed", "debris is cleared");

  const companion = await start({ socketPath, assetsDir });
  t.after(() => companion.stop());
  // A *running* companion must not be unlinked out from under itself.
  await assert.rejects(
    () => start({ socketPath, assetsDir }),
    /already listening/,
    "a live companion is refused rather than displaced"
  );
});

test("the socket path is chosen predictably and arguments are validated", () => {
  assert.equal(
    defaultSocketPath({ XDG_RUNTIME_DIR: "/run/user/501" }, 501),
    "/run/user/501/md-viewer-501.sock",
    "XDG_RUNTIME_DIR is preferred when set"
  );
  assert.equal(
    defaultSocketPath({}, 501),
    path.join(os.tmpdir(), "md-viewer-501.sock"),
    "the temp directory is the fallback"
  );
  // Qualified by uid so two users on one shared temp directory cannot collide.
  assert.notEqual(defaultSocketPath({}, 501), defaultSocketPath({}, 502));

  assert.deepEqual(parseArgs([]), { socket: null });
  assert.deepEqual(parseArgs(["--socket", "/tmp/x.sock"]), { socket: "/tmp/x.sock" });
  assert.throws(() => parseArgs(["--socket"]), /needs a path/);
  assert.throws(() => parseArgs(["--port", "4444"]), /unknown argument/);
});
