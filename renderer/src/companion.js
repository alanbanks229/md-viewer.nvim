// The renderer as a long-lived companion, reached over a unix domain socket.
//
// Why this exists: over a throttled SSH link the pixels are the cost, and the
// only way to stop paying it is to rasterize on the machine the *terminal* is
// on rather than the machine Neovim is on. That machine cannot be reached
// inbound, so the plugin dials out to a socket its own `ssh -R` forwarded here.
// docs/local-render-design.md has the measurements and the whole architecture.
//
// **What this is not, yet.** Render responses hand back `pngPath`, a path in
// *this* machine's temp directory, and the Lua side opens it directly. Across
// two machines that path does not resolve, so a companion is only useful today
// when it runs beside the Neovim it serves -- which is exactly what makes this
// phase testable on one machine. Replacing the path with an in-stream
// transmission token is the next phase's job, and until it lands this
// entrypoint is infrastructure rather than a feature.
//
// **Invariant: unix domain socket, never TCP.** The claim this narrows is "the
// renderer opens no listening port". On the machine running Neovim that stays
// literally true -- the plugin only ever dials out, and the listener on that
// side belongs to sshd because a user asked for a forward. Here, on the client,
// the listener is a filesystem object with mode 0600 that nothing off-machine
// can address. `tests/node/companion.test.js` asserts both halves.
//
// Usage:
//     node renderer/src/companion.js [--socket <path>]
//
// The path also comes from $MD_VIEWER_COMPANION_SOCKET, and defaults to
// $XDG_RUNTIME_DIR (or the temp directory) plus a uid-qualified name.

import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { LineProtocol } from "./protocol.js";
import { createService } from "./service.js";

const directory = path.dirname(fileURLToPath(import.meta.url));

export function defaultSocketPath(env = process.env, uid = process.getuid?.()) {
  const base = env.XDG_RUNTIME_DIR && env.XDG_RUNTIME_DIR !== "" ? env.XDG_RUNTIME_DIR : os.tmpdir();
  // Qualified by uid rather than by username: on a shared temp directory two
  // users must not race for the same path, and a name is not guaranteed to be
  // filesystem-safe where a uid always is.
  return path.join(base, `md-viewer-${uid ?? "user"}.sock`);
}

export function parseArgs(argv) {
  const options = { socket: null };
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--socket") {
      options.socket = argv[index + 1];
      index += 1;
      if (typeof options.socket !== "string" || options.socket === "") {
        throw new Error("--socket needs a path");
      }
    } else {
      throw new Error(`unknown argument: ${argv[index]}`);
    }
  }
  return options;
}

/// Remove a socket file left behind by a companion that did not exit cleanly.
///
/// Probed rather than assumed: an existing path might be a *running* companion,
/// and unlinking that would silently steal the socket from a live session while
/// leaving it connected. Connecting is the only way to tell the two apart --
/// ECONNREFUSED means nothing is listening and the file is debris.
export function clearStaleSocket(socketPath) {
  return new Promise((resolve, reject) => {
    if (!fs.existsSync(socketPath)) {
      resolve("absent");
      return;
    }
    const probe = net.connect(socketPath);
    const giveUp = setTimeout(() => {
      probe.destroy();
      reject(new Error(`a companion is already listening on ${socketPath}`));
    }, 1000);
    probe.on("connect", () => {
      clearTimeout(giveUp);
      probe.destroy();
      reject(new Error(`a companion is already listening on ${socketPath}`));
    });
    probe.on("error", () => {
      clearTimeout(giveUp);
      try {
        fs.unlinkSync(socketPath);
      } catch (error) {
        reject(error);
        return;
      }
      resolve("removed");
    });
  });
}

/// Start serving. Exported so a test can drive a real socket without a
/// subprocess, and so the path is returned rather than only printed.
export async function start({ socketPath, assetsDir, onListening } = {}) {
  const resolved = socketPath ?? defaultSocketPath();
  await clearStaleSocket(resolved);

  const service = createService({ assetsDir: assetsDir ?? path.resolve(directory, "../assets") });
  let active = null;

  const server = net.createServer((socket) => {
    // One connection at a time, newest wins. The service owns one browser, one
    // page and one serial queue, so two clients would share a document cache
    // and a lane registry and supersede each other's renders. Newest wins
    // rather than oldest because the common case for a second connection is a
    // Neovim that restarted while the old socket had not yet been noticed as
    // dead -- refusing there would make the companion need a restart too.
    if (active && !active.destroyed) active.destroy();
    active = socket;
    socket.on("error", () => socket.destroy());
    socket.on("close", () => {
      if (active !== socket) return;
      active = null;
      // Document ids are buffer numbers, so the next session would otherwise
      // inherit this one's cache under the same ids. See service.forgetAll.
      service.forgetAll();
    });
    const protocol = new LineProtocol(socket, socket, async (request) => {
      // `shutdown` means "this session is done", not "stop the server". A
      // companion outlives any one Neovim, and tearing the browser down here
      // would make every reconnect pay a cold Chromium launch -- which is the
      // cost a long-lived companion exists to avoid. Signals are how it stops.
      if (request.method === "shutdown") return { shutdown: true };
      return service.dispatch(request);
    });
    protocol.start();
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    // Created 0600 by umask rather than chmod'ed to it afterwards: a chmod
    // leaves a window in which the socket exists and is group/world reachable,
    // and this is the only thing standing between a forwarded port and anything
    // else on the machine.
    const previousMask = process.umask(0o177);
    try {
      server.listen(resolved, () => {
        server.removeListener("error", reject);
        resolve();
      });
    } finally {
      process.umask(previousMask);
    }
  });

  if (onListening) onListening(resolved);

  let stopping = false;
  async function stop() {
    if (stopping) return;
    stopping = true;
    // `server.close()` waits for every open connection, and a client is under
    // no obligation to hang up first -- a companion told to stop has to stop,
    // not hang until the far end notices. Dropping the connections is what
    // makes the close callback actually fire.
    if (active && !active.destroyed) active.destroy();
    active = null;
    server.closeAllConnections?.();
    await new Promise((resolve) => server.close(resolve));
    try {
      fs.unlinkSync(resolved);
    } catch {}
    await service.close();
  }

  return { socketPath: resolved, server, service, stop };
}

// Only when run as a program, so importing this for a test starts nothing.
if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const options = parseArgs(process.argv.slice(2));
  const socketPath = options.socket ?? process.env.MD_VIEWER_COMPANION_SOCKET ?? defaultSocketPath();
  const started = await start({
    socketPath,
    onListening: (listening) => {
      // stdout, and machine-readable first: a launcher script reads this line
      // to learn the path it must forward, and a human reads the rest.
      process.stdout.write(`${listening}\n`);
      process.stderr.write(`md-viewer companion listening on ${listening}\n`);
    },
  });
  const stopAndExit = async () => {
    await started.stop();
    process.exit(0);
  };
  process.on("SIGTERM", stopAndExit);
  process.on("SIGINT", stopAndExit);
}
