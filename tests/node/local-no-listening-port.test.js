import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

// The helper re-narrows the plugin's listening invariant rather than eroding
// it: one unix-domain socket on the operator's machine is the whole allowance,
// and TCP stays at zero -- asserted here the same way
// `no-listening-port.test.js` asserts it of the renderer, against the real
// running process rather than by reading the code.

const here = path.dirname(fileURLToPath(import.meta.url));

function listeningTcpPorts() {
  try {
    const out = execFileSync("lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n"], { encoding: "utf8" });
    return new Set(out.split("\n").filter(Boolean));
  } catch (error) {
    if (error.status === 1 && !error.stdout) return new Set();
    throw error;
  }
}

test("the running helper opens no listening TCP port", { skip: (() => {
  try { execFileSync("lsof", ["-v"]); return false; } catch { return "lsof is not available on this runner"; }
})() }, async (t) => {
  const before = listeningTcpPorts();
  const main = path.resolve(here, "../../renderer/src/local-main.js");
  const child = spawn(process.execPath, [main, "--", process.execPath, "-e", "setInterval(() => {}, 1000)"], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => { if (child.exitCode === null) child.kill("SIGKILL"); });

  // Give it time to finish startup (probe skip, wiring) and settle.
  await new Promise((resolve) => setTimeout(resolve, 700));
  assert.equal(child.exitCode, null, "the helper should still be running around its wrapped child");

  const after = listeningTcpPorts();
  const opened = [...after].filter((line) => !before.has(line));
  assert.deepEqual(opened, [], "no new listening TCP port appeared while the helper ran");

  child.kill("SIGTERM");
  await new Promise((resolve) => child.once("exit", resolve));
});
