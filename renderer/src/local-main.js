// The local-render helper as the operator launches it: a process that wraps
// the ssh session on the *terminal's* machine and owns exactly one thing --
// the bytes flowing from ssh to the tty.
//
//   node renderer/src/local-main.js -- ssh <host>
//
// Topology, and why it is this one: stdin is inherited, so ssh itself owns
// the real terminal for input -- raw mode, window-size changes, `~` escapes
// all belong to ssh exactly as they do without the helper, and the two
// alternatives `docs/local-render-design.md` records as impossible (a second
// tty writer; owning stdin) stay untouched. Only stdout is piped: every byte
// ssh produces passes through the stream parser, which deletes matched
// marker APCs and reports the safe boundaries where the injector may write a
// graphics transaction. stderr is piped too, and forwarded only at safe
// boundaries -- an ssh "Connection closed" landing inside an injected upload
// chunk is precisely the two-writer wedge this design exists to avoid.
//
// Lifecycle mirrors main.js's hardening: the helper's lifetime is the
// wrapped command's. The child exiting ends the helper (after flushing the
// parser and writing targeted deletions for every image it injected);
// signals and a dead stdout end the child; an unref'd hard-exit backstop
// guarantees neither a hung teardown nor a rejecting cleanup can strand the
// process. If the helper itself is killed outright (SIGKILL), ssh dies on
// its next write to the broken pipe and restores the tty modes it owns.
//
// `--marker-echo-test` is the K2 rig: it counts and sequence-checks markers
// arriving through the real remote path without rendering anything, so
// marker transit integrity can be measured on a link (SSM included) before
// anything depends on it. Pair it with scripts/local/marker-echo-emit.sh on
// the remote side.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn, execFileSync } from "node:child_process";
import { StreamParser } from "./local/stream-parser.js";
import { Injector } from "./local/injector.js";
import { markerPrefix, parseMarkerPayload } from "./local/markers.js";
import { probeTerminal } from "./local/tty-probe.js";
import { SocketService } from "./local/socket-service.js";
import { createReplica } from "./local/replica.js";

const here = path.dirname(fileURLToPath(import.meta.url));

function helperVersion() {
  const pkg = JSON.parse(fs.readFileSync(path.join(here, "../package.json"), "utf8"));
  let commit = "unknown";
  try {
    commit = execFileSync("git", ["-C", here, "rev-parse", "--short", "HEAD"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {}
  return `md-viewer-local v${pkg.version} (${commit})`;
}

function usage() {
  return [
    "usage: node renderer/src/local-main.js [--version] [--marker-echo-test] -- <command...>",
    "",
    "Wraps an interactive command (normally `ssh <host>`) and filters its",
    "output for md-viewer local-render markers. Run it in place of the plain",
    "ssh invocation, on the machine the terminal is on.",
  ].join("\n");
}

function parseArgs(argv) {
  const flags = { version: false, echoTest: false };
  let command = null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (command !== null) {
      command.push(arg);
    } else if (arg === "--") {
      command = [];
    } else if (arg === "--version") {
      flags.version = true;
    } else if (arg === "--marker-echo-test") {
      flags.echoTest = true;
    } else if (arg.startsWith("--")) {
      throw new Error(`unknown flag: ${arg}\n${usage()}`);
    } else {
      // Convenience: `local-main.js ssh host` without the `--`.
      command = [arg];
    }
  }
  return { flags, command: command ?? [] };
}

let flags;
let command;
try {
  ({ flags, command } = parseArgs(process.argv.slice(2)));
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(2);
}

if (flags.version) {
  process.stdout.write(`${helperVersion()}\n`);
  process.exit(0);
}

if (command.length === 0) {
  process.stderr.write(`${usage()}\n`);
  process.exit(2);
}

// Every route out funnels through here, exactly like main.js: cleanup is
// best-effort, exiting is not negotiable.
let exiting = false;
let cleanup = () => {};
function exit(code) {
  if (exiting) return;
  exiting = true;
  setTimeout(() => process.exit(code), 2000).unref();
  Promise.resolve()
    .then(() => cleanup())
    .catch(() => {})
    .finally(() => process.exit(code));
}

const probe = await probeTerminal();
if (probe.skipped) {
  process.stderr.write(`md-viewer-local: ${probe.skipped}; terminal probe skipped\n`);
}

// The token markers must carry to be acted on. In normal operation it is
// random per run and reaches the remote plugin only over the control socket;
// in echo-test mode it is printed (or taken from the environment) so the
// remote emitter script can be handed it by the operator.
const token = flags.echoTest
  ? process.env.MD_VIEWER_ECHO_TOKEN ?? crypto.randomBytes(16).toString("hex")
  : crypto.randomBytes(16).toString("hex");
if (flags.echoTest) process.stderr.write(`marker-echo token: ${token}\n`);

const write = (buf) => process.stdout.write(buf);

// stderr forwarding: same single writer, safe boundaries only. A short timer
// drains it even when the stdout stream has gone quiet mid-sequence.
let stderrQueue = [];
let stderrTimer = null;
function flushStderr(force) {
  if (stderrQueue.length === 0) return;
  if (!force && !parser.atSafeBoundary()) return;
  const chunks = stderrQueue;
  stderrQueue = [];
  for (const chunk of chunks) write(chunk);
}
function queueStderr(chunk) {
  stderrQueue.push(chunk);
  flushStderr(false);
  if (stderrQueue.length > 0 && stderrTimer === null) {
    stderrTimer = setInterval(() => {
      flushStderr(false);
      if (stderrQueue.length === 0 && stderrTimer !== null) {
        clearInterval(stderrTimer);
        stderrTimer = null;
      }
    }, 50);
    stderrTimer.unref();
  }
}

const echo = { received: 0, malformed: 0, outOfOrder: 0, maxSeq: -1, lastSeq: -1 };
let injector = null;

const parser = new StreamParser({
  markerPrefix: markerPrefix(token),
  onData: write,
  onMarker: (payload) => {
    if (flags.echoTest) {
      try {
        const parsed = parseMarkerPayload(payload);
        echo.received += 1;
        if (parsed.seq <= echo.lastSeq) echo.outOfOrder += 1;
        echo.lastSeq = parsed.seq;
        echo.maxSeq = Math.max(echo.maxSeq, parsed.seq);
      } catch {
        echo.malformed += 1;
      }
      return;
    }
    injector.acceptMarker(payload);
  },
});

let service = null;
let replica = null;
if (!flags.echoTest) {
  service = new SocketService({ token, helperVersion: helperVersion(), probe });
  replica = createReplica({
    assetsDir: path.resolve(here, "../assets"),
    onNotify: (event, fields) => service.notify(event, fields),
    onSurfaceReady: () => {
      if (parser.atSafeBoundary()) injector.tryInject();
    },
  });
  service.setRequestHandler(replica.handle);
  injector = new Injector({
    token,
    write,
    resolveUpload: (upload, doc) => replica.resolveUpload(upload, doc),
    boundary: () => parser.atSafeBoundary(),
    // The pairing probe: the plugin emitted a seq-0 marker through its own
    // tty; only the helper filtering *this* terminal sees it, so answering
    // over the socket is the proof that socket and terminal belong together.
    onPairing: () => service.notify("presented", { seq: 0 }),
  });
  injector.onInjected = (tx) =>
    service.notify("presented", { seq: tx.seq, doc: tx.doc, scrollY: tx.uploads[0]?.scrollY ?? null });
  try {
    await service.listen();
  } catch (error) {
    process.stderr.write(`md-viewer-local: ${error.message}\n`);
    process.exit(1);
  }
}

// When wrapping ssh, add the reverse forward that lets the remote plugin
// reach the socket. The remote path must be absolute (sshd refuses relative
// streamlocal binds -- measured 2026-08-26) and short (sun_path), so it lives
// under /tmp/md-viewer-<user>, with the user resolved from the operator's own
// ssh config via `ssh -G` -- no connection is made to find it out. The plugin
// verifies ownership and permissions before ever using the directory, and the
// pairing probe makes a spoofed socket unadoptable regardless.
let effectiveCommand = command;
if (service && command[0] === "ssh") {
  try {
    const resolved = execFileSync("ssh", ["-G", ...command.slice(1)], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
    const user = /^user (\S+)$/m.exec(resolved)?.[1];
    if (user) {
      const remoteSock = `/tmp/md-viewer-${user}/r-${crypto.randomBytes(4).toString("hex")}.sock`;
      effectiveCommand = [command[0], "-R", `${remoteSock}:${service.socketPath}`, ...command.slice(1)];
    } else {
      process.stderr.write("md-viewer-local: could not resolve the remote user from ssh -G; no forward added\n");
    }
  } catch {
    process.stderr.write("md-viewer-local: ssh -G failed; no forward added (local rendering will not attach)\n");
  }
}

const child = spawn(effectiveCommand[0], effectiveCommand.slice(1), { stdio: ["inherit", "pipe", "pipe"] });

child.on("error", (error) => {
  process.stderr.write(`md-viewer-local: failed to run ${command[0]}: ${error.message}\n`);
  exit(127);
});

child.stdout.on("data", (chunk) => {
  parser.push(chunk);
  if (injector && parser.atSafeBoundary()) injector.tryInject();
  flushStderr(false);
});

child.stderr.on("data", queueStderr);

cleanup = () => {
  parser.flush();
  flushStderr(true);
  if (injector) {
    const bytes = injector.teardown();
    if (bytes.length > 0) write(bytes);
  }
  if (service) service.close();
  if (flags.echoTest) {
    // The emitter numbers markers 1..N, so max-seq is also the emitted count.
    const missing = echo.maxSeq >= 1 ? echo.maxSeq - echo.received : 0;
    process.stderr.write(
      `marker-echo: received=${echo.received} max-seq=${echo.maxSeq} missing=${missing} ` +
        `out-of-order=${echo.outOfOrder} malformed=${echo.malformed} ` +
        `rejected-candidates=${parser.stats.rejectedCandidates}\n`
    );
  }
  // Kill the child before the (awaited) browser teardown, never after a
  // return that skips it -- a wrapper that forgets this line is exactly how
  // orphans happen, and the orphan-exit test caught this one being ordered
  // wrong.
  if (child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
  if (replica) return replica.close();
};

child.on("exit", (code, signal) => {
  exit(code ?? (signal ? 1 : 0));
});

process.on("SIGTERM", () => exit(0));
process.on("SIGINT", () => exit(0));
process.on("SIGHUP", () => exit(0));
// The terminal going away reaches us as a dead stdout before anything else.
process.stdout.on("error", () => exit(1));

process.on("uncaughtException", (error) => {
  try {
    process.stderr.write(`md-viewer-local fatal: ${error.stack ?? error.message}\n`);
  } catch {}
  exit(1);
});
process.on("unhandledRejection", (reason) => {
  try {
    process.stderr.write(`md-viewer-local unhandled rejection: ${reason?.stack ?? reason}\n`);
  } catch {}
  exit(1);
});
