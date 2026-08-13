// `bin/md-viewer-ssh` -- the one component whose bugs cost the whole session.
//
// It sits between a live terminal and a live ssh, so the properties that matter
// most are the boring ones: every byte ssh writes reaches the terminal, exactly
// once, in order; the exit status is ssh's; and nothing this adds can stop
// output arriving. Those are checked here against a stand-in `ssh` on PATH,
// which is what makes them checkable at all -- a real remote host is not
// available in CI and would not be more convincing.
//
// The last test is the end-to-end one, and the only one that needs a browser:
// a stand-in ssh that talks the real protocol to the real companion, gets a
// real frame reference back, and emits the token for it -- and the wrapper's
// stdout then carries the real Kitty upload of exactly those bytes. That is the
// whole design, running, on one machine.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const WRAPPER = path.resolve(here, "../../bin/md-viewer-ssh");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

/// Put a stand-in `ssh` first on PATH. `body` is the JS the fake runs; it
/// receives the wrapper's arguments in `process.argv.slice(2)` exactly as ssh
/// would, and its environment is the one the wrapper built.
function fakeSsh(t, body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mdv-ssh-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const script = path.join(dir, "fake-ssh.mjs");
  fs.writeFileSync(script, body);
  const shim = path.join(dir, "ssh");
  fs.writeFileSync(shim, `#!/bin/sh\nexec ${JSON.stringify(process.execPath)} ${JSON.stringify(script)} "$@"\n`);
  fs.chmodSync(shim, 0o755);
  return dir;
}

function runWrapper(t, { args, pathDir, env = {} }) {
  const socket = path.join(os.tmpdir(), `mdv-wrap-${process.pid}-${args.join("_").replace(/\W/g, "")}.sock`);
  const log = path.join(os.tmpdir(), `mdv-wrap-${process.pid}.log`);
  t.after(() => {
    for (const file of [socket, log]) {
      try { fs.unlinkSync(file); } catch {}
    }
  });
  const child = spawn(
    process.execPath,
    [WRAPPER, "--md-viewer-socket", socket, "--md-viewer-log", log, ...args],
    {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, ...env, PATH: `${pathDir}:${process.env.PATH}`, MDV_TEST_SOCKET: socket },
    }
  );
  const stdout = [];
  const stderr = [];
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.push(chunk));
  return new Promise((resolve) => {
    child.once("exit", (code) => {
      resolve({ code, stdout: Buffer.concat(stdout), stderr: Buffer.concat(stderr), socket, log });
    });
  });
}

test("every byte ssh writes reaches the terminal, once, in order", async (t) => {
  // Deliberately awkward output: escape sequences, a lone ESC, a partial APC,
  // and something that looks like the marker but is not. All of it has to come
  // back unchanged -- a filter that eats one byte of a session is worse than no
  // filter at all.
  const pathDir = fakeSsh(t, `
    import process from "node:process";
    const parts = [];
    for (let i = 0; i < 400; i += 1) {
      parts.push(\`line \${i} \\u001b[32mgreen\\u001b[0m \\u001b_Ga=t,f=100;AAAA\\u001b\\\\\`);
      parts.push("\\u001b");
      parts.push("_MDV");
      parts.push("2;not-a-token\\u001b\\\\");
      parts.push("\\u001b_MDV1;");
    }
    for (const part of parts) process.stdout.write(part);
    process.exit(0);
  `);
  const run = await runWrapper(t, { args: ["--md-viewer-no-render", "host"], pathDir });
  assert.equal(run.code, 0);

  const expected = [];
  for (let i = 0; i < 400; i += 1) {
    expected.push(`line ${i} [32mgreen[0m _Ga=t,f=100;AAAA\\`);
    expected.push("", "_MDV", "2;not-a-token\\", "_MDV1;");
  }
  assert.deepEqual(run.stdout, Buffer.from(expected.join(""), "latin1"));
});

test("a passthrough with a splicer in the path is still byte-identical", async (t) => {
  // Same stream, but with the companion running -- so the splicer is actually
  // scanning every byte, including a trailing bare marker it must release at
  // end of stream rather than swallow.
  const pathDir = fakeSsh(t, `
    import process from "node:process";
    process.stdout.write("prologue \\u001b[1mbold\\u001b[0m\\n");
    process.stdout.write("\\u001b_MDV1;tx;nosuchframe;a=t,f=100,t=d,q=2,i=9\\u001b\\\\");
    process.stdout.write("epilogue\\n\\u001b_MDV1;");
    process.exit(3);
  `);
  const run = await runWrapper(t, { args: ["host"], pathDir });
  assert.equal(run.code, 3, "ssh's exit status is the wrapper's exit status");
  assert.equal(
    run.stdout.toString("latin1"),
    "prologue [1mbold[0m\n"
      + "_MDV1;tx;nosuchframe;a=t,f=100,t=d,q=2,i=9\\"
      + "epilogue\n_MDV1;",
    "an unknown reference is forwarded, and a partial marker at end of stream is released"
  );
});

test("the handshake announces the wrapper and only the wrapper", async (t) => {
  const pathDir = fakeSsh(t, `
    import process from "node:process";
    process.stdout.write(JSON.stringify({ lc: process.env.LC_MD_VIEWER ?? null, args: process.argv.slice(2) }));
    process.exit(0);
  `);

  const withRender = await runWrapper(t, { args: ["-p", "2222", "host", "nvim"], pathDir });
  const seen = JSON.parse(withRender.stdout.toString());
  assert.equal(seen.lc, "v=1", "the far end is told the protocol version");
  assert.deepEqual(seen.args, ["-p", "2222", "host", "nvim"], "and every other argument is ssh's, untouched");

  const withAddress = await runWrapper(t, { args: ["--md-viewer-addr", "127.0.0.1:4445", "host"], pathDir });
  assert.equal(JSON.parse(withAddress.stdout.toString()).lc, "v=1,addr=127.0.0.1:4445");

  // Without a companion there is nothing to splice, so a token would be a
  // frame that never appears. An inherited value from an outer session must not
  // be allowed to say otherwise.
  const disabled = await runWrapper(t, {
    args: ["--md-viewer-no-render", "host"],
    pathDir,
    env: { LC_MD_VIEWER: "v=1,addr=stale" },
  });
  assert.equal(JSON.parse(disabled.stdout.toString()).lc, null, "a stale handshake is cleared, never inherited");
});

test("a signalled ssh is reported the way a shell reports one", async (t) => {
  const pathDir = fakeSsh(t, `
    import process from "node:process";
    process.kill(process.pid, "SIGTERM");
    setTimeout(() => {}, 1000);
  `);
  const run = await runWrapper(t, { args: ["--md-viewer-no-render", "host"], pathDir });
  assert.equal(run.code, 128 + os.constants.signals.SIGTERM);
});

test("a remote render reaches the terminal as the real upload, over one link", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  // The stand-in ssh plays the part of the remote Neovim: it dials the
  // companion socket (which is what the `-R` forward is for in a real session),
  // renders a document by reference, and writes the token the plugin would
  // write. Everything from there is the wrapper's job.
  const pathDir = fakeSsh(t, `
    import net from "node:net";
    import readline from "node:readline";

    const socket = net.connect(process.env.MDV_TEST_SOCKET);
    await new Promise((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
    });
    const reader = readline.createInterface({ input: socket });
    const answers = new Map();
    reader.on("line", (line) => {
      const message = JSON.parse(line);
      answers.set(message.id, message);
    });
    function ask(id, method, params) {
      socket.write(JSON.stringify({ id, method, params }) + "\\n");
      return new Promise((resolve) => {
        const poll = setInterval(() => {
          if (answers.has(id)) { clearInterval(poll); resolve(answers.get(id)); }
        }, 10);
      });
    }
    const response = await ask(1, "render", {
      documentId: "wrapped",
      markdown: "# Rendered on the machine the terminal is on\\n\\nWith prose under it.\\n",
      contentRevision: "1:0",
      baseDir: process.cwd(),
      documentRoot: process.cwd(),
      viewport: { widthPx: 400, heightPx: 300, deviceScaleFactor: 1 },
      scrollY: 0, theme: "dark", rawHtml: false, localImages: false, maxLocalImageBytes: 1024,
      frameTransport: "ref",
      browser: { executable_path: ${JSON.stringify(executable)}, launch_timeout_ms: 30000 },
    });
    if (!response.ok) {
      process.stderr.write("render failed: " + response.error + "\\n");
      process.exit(1);
    }
    const { frameRef, pngBytes, pngWidth, pngHeight } = response.result;
    // Announced on stderr, which the wrapper does not filter, so the test can
    // read what to expect without it passing through the thing under test.
    process.stderr.write(JSON.stringify({ frameRef, pngBytes, pngWidth, pngHeight }) + "\\n");
    process.stdout.write("BEGIN");
    process.stdout.write("\\u001b_MDV1;tx;" + frameRef + ";a=t,f=100,t=d,q=2,i=77\\u001b\\\\");
    process.stdout.write("END");
    socket.end();
    process.exit(0);
  `);

  const run = await runWrapper(t, { args: ["host"], pathDir });
  assert.equal(run.code, 0, `wrapper failed: ${run.stderr.toString()}`);
  const announced = JSON.parse(run.stderr.toString().trim().split("\n").pop());
  assert.equal(announced.pngBytes > 0, true);
  assert.equal(announced.pngWidth > 0, true, "the reference carries the dimensions Lua would have measured");

  const out = run.stdout.toString("latin1");
  assert.equal(out.startsWith("BEGIN"), true);
  assert.equal(out.endsWith("END"), true);
  assert.equal(out.includes("MDV1"), false, "no token survives to the terminal");

  const upload = out.slice("BEGIN".length, out.length - "END".length);
  assert.equal(upload.startsWith("_Ga=t,f=100,t=d,q=2,i=77,m="), true, "it is a Kitty transmission");
  const commands = upload.split("_G").slice(1);
  const payload = commands.map((c) => c.slice(c.indexOf(";") + 1, -2)).join("");
  const bytes = Buffer.from(payload, "base64");
  assert.equal(bytes.length, announced.pngBytes, "carrying exactly the frame that was rendered");
  assert.equal(bytes.subarray(1, 4).toString("latin1"), "PNG");
  assert.equal(bytes.readUInt32BE(16), announced.pngWidth);

  // And the size claim the whole design rests on, measured rather than argued.
  const tokenBytes = `_MDV1;tx;${announced.frameRef};a=t,f=100,t=d,q=2,i=77\\`.length;
  assert.equal(
    upload.length > tokenBytes * 20,
    true,
    `the token was ${tokenBytes} bytes and the upload it stood for was ${upload.length}`
  );
});
