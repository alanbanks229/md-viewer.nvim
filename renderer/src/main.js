// The renderer as Neovim spawns it: one child process, requests on stdin,
// responses on stdout, nothing else.
//
// This file is deliberately the whole of what "how requests arrive" means, and
// it is deliberately tiny. What a request *does* is in service.js, so the two
// questions stay separable.
//
// **Invariant:** this process opens no listening port of any kind, and neither
// does the Chromium it launches. `tests/node/no-listening-port.test.js` asserts
// it against this entrypoint and its real browser child rather than trusting
// that no code calls `createServer`, because a dependency could introduce one
// without anything here changing.

import path from "node:path";
import { fileURLToPath } from "node:url";
import { LineProtocol } from "./protocol.js";
import { createService } from "./service.js";

const directory = path.dirname(fileURLToPath(import.meta.url));

// Exiting is this entrypoint's decision, not the service's: a child owned by
// Neovim must stop when Neovim says so. `setImmediate` lets the reply reach
// stdout first -- the plugin waits for it before closing the pipe.
const service = createService({
  assetsDir: path.resolve(directory, "../assets"),
  onShutdown: () => setImmediate(() => exit(0)),
});

const protocol = new LineProtocol(process.stdin, process.stdout, service.dispatch);
protocol.start();

// Every route out of this process funnels through `exit`, and `exit` cannot
// fail. That is the whole point of it: the previous version awaited
// `service.close()` unguarded and called `process.exit(0)` only afterwards, so
// a rejecting `browser.close()` -- the *normal* case once Chromium's pipe is
// already dead -- skipped the exit entirely and left a rejected promise behind.
// Node rethrew that as an uncaught exception, the handler re-entered shutdown,
// found `service.closing` already true and returned without exiting, and the
// process span at 100% of a core formatting stack traces until it was killed.
// Cleanup here is best-effort; exiting is not negotiable.
let exiting = false;
function exit(code) {
  if (exiting) return;
  exiting = true;
  // A `browser.close()` that hangs must not become a third way to never exit.
  setTimeout(() => process.exit(code), 2000).unref();
  Promise.resolve()
    .then(() => service.close())
    .catch(() => {})
    .finally(() => process.exit(code));
}

process.on("SIGTERM", () => exit(0));
process.on("SIGINT", () => exit(0));
// A closed terminal is the common way this process loses its Neovim.
process.on("SIGHUP", () => exit(0));

// Neovim closing the pipe is the only notice we get when it goes away without
// asking: a crash, a SIGKILL, a terminal window shut. A child owned by Neovim
// that cannot detect this outlives it forever, which is exactly how nine
// renderers once accumulated across a week.
process.stdin.on("close", () => exit(0));
process.stdin.on("end", () => exit(0));
process.stdin.on("error", () => exit(0));
// EPIPE on the response pipe means the same thing, and reaches us first if a
// reply is in flight when Neovim dies. Handling it here keeps it from arriving
// as the uncaught exception that used to start the spin.
process.stdout.on("error", () => exit(0));

process.on("uncaughtException", (error) => {
  // Throwing inside this handler is fatal, and stderr may itself be a dead
  // pipe by now -- the reason we are here at all.
  try {
    process.stderr.write(`md-viewer renderer fatal: ${error.stack ?? error.message}\n`);
  } catch {}
  exit(1);
});
// Without this, Node's default for an unhandled rejection is to rethrow it as
// an uncaught exception, which is the loop described above.
process.on("unhandledRejection", (reason) => {
  try {
    process.stderr.write(`md-viewer renderer unhandled rejection: ${reason?.stack ?? reason}\n`);
  } catch {}
  exit(1);
});
