// The renderer as Neovim spawns it: one child process, requests on stdin,
// responses on stdout, nothing else.
//
// This file is deliberately the whole of what "how requests arrive" means for
// the default configuration, and it is deliberately tiny. What a request *does*
// is in service.js, which is shared with companion.js -- so the two transports
// cannot drift into answering the same request differently.
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
  onShutdown: () => setImmediate(() => process.exit(0)),
});

const protocol = new LineProtocol(process.stdin, process.stdout, service.dispatch);
protocol.start();

async function shutdown() {
  if (service.closing) return;
  await service.close();
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.on("uncaughtException", (error) => {
  process.stderr.write(`md-viewer renderer fatal: ${error.stack ?? error.message}\n`);
  shutdown();
});
