import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

// The helper's lifetime is the wrapped command's, in both directions: the
// child exiting ends the helper (with the child's code, so scripts around
// `ssh` keep working), and the helper being told to stop takes the child down
// rather than orphaning it. Same guarantee family as orphan-exit.test.js
// pins for the renderer, and for the same reason -- a wrapper that can
// outlive or strand its partner accumulates.

const here = path.dirname(fileURLToPath(import.meta.url));
const main = path.resolve(here, "../../renderer/src/local-main.js");

function collect(stream) {
  const chunks = [];
  stream.on("data", (chunk) => chunks.push(chunk));
  return () => Buffer.concat(chunks).toString("utf8");
}

function aliveProcess(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

test("the helper exits with its child's code when the child ends", async () => {
  const child = spawn(process.execPath, [main, "--", process.execPath, "-e", "process.stdout.write('bye'); process.exit(7)"], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stdout = collect(child.stdout);
  const code = await new Promise((resolve) => child.once("exit", resolve));
  assert.equal(code, 7, "ssh's exit code must survive the wrapper");
  assert.ok(stdout().includes("bye"), "output written just before exit is flushed, not dropped");
});

test("stopping the helper takes the wrapped child down with it", async (t) => {
  const marker = `mdv-orphan-${process.pid}-${Date.now()}`;
  const helper = spawn(
    process.execPath,
    [main, "--", process.execPath, "-e", `process.title=${JSON.stringify(marker)}; console.log('PID='+process.pid); setInterval(() => {}, 1000)`],
    { stdio: ["ignore", "pipe", "pipe"] }
  );
  t.after(() => { if (helper.exitCode === null) helper.kill("SIGKILL"); });

  const childPid = await new Promise((resolve, reject) => {
    let buffer = "";
    const timer = setTimeout(() => reject(new Error("wrapped child never reported its pid")), 5000);
    helper.stdout.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const match = /PID=(\d+)/.exec(buffer);
      if (match) {
        clearTimeout(timer);
        resolve(Number(match[1]));
      }
    });
  });
  assert.ok(aliveProcess(childPid));

  helper.kill("SIGTERM");
  await new Promise((resolve) => helper.once("exit", resolve));
  // The SIGTERM the helper forwards needs a moment to land.
  const deadline = Date.now() + 3000;
  while (aliveProcess(childPid) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(aliveProcess(childPid), false, "the wrapped child must not outlive the helper");
});

test("echo mode counts markers off the real pipe path and passes everything else through", async () => {
  const token = "aa".repeat(16);
  const count = 200;
  const emitter = `
    const token = ${JSON.stringify(token)};
    let out = "before-markers\\n";
    for (let i = 1; i <= ${count}; i += 1) {
      out += "\\x1b_Mv=1;t=" + token + ";s=" + i + ";d=echo;p=;x=\\x1b\\\\";
      if (i % 40 === 0) out += "noise " + i + "\\x1b[K\\r";
    }
    out += "after-markers\\n";
    process.stdout.write(out);
  `;
  const helper = spawn(process.execPath, [main, "--marker-echo-test", "--", process.execPath, "-e", emitter], {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, MD_VIEWER_ECHO_TOKEN: token },
  });
  const stdout = collect(helper.stdout);
  const stderr = collect(helper.stderr);
  const code = await new Promise((resolve) => helper.once("exit", resolve));
  assert.equal(code, 0);
  assert.match(stderr(), new RegExp(`received=${count} max-seq=${count} missing=0 out-of-order=0 malformed=0`));
  assert.ok(stdout().includes("before-markers"), "ordinary output still reaches the terminal");
  assert.ok(stdout().includes("after-markers"));
  assert.ok(!stdout().includes("\x1b_M"), "matched markers are swallowed, not forwarded");
});
