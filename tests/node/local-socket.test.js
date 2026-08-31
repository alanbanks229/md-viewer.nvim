import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { SocketService } from "../../renderer/src/local/socket-service.js";
import { LOCAL_PROTOCOL } from "../../renderer/src/local/version.js";

// The hello handshake is where version skew and socket hygiene are enforced,
// so it is tested against a real listener and real connections, not mocks.

const TOKEN = "cc".repeat(16);

function makeService(overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mdv-sk-"));
  const service = new SocketService({
    token: TOKEN,
    helperVersion: "md-viewer-local vtest",
    probe: { kittyGraphics: "verified", cellPixels: { widthPx: 10, heightPx: 20 }, da1: "\x1b[?1c", skipped: null },
    dir,
    ...overrides,
  });
  return { service, dir };
}

function connectClient(socketPath) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath, () => {
      const lines = [];
      const waiters = [];
      let buffer = "";
      socket.on("data", (chunk) => {
        buffer += chunk.toString("utf8");
        let idx;
        while ((idx = buffer.indexOf("\n")) !== -1) {
          const line = JSON.parse(buffer.slice(0, idx));
          buffer = buffer.slice(idx + 1);
          const waiter = waiters.shift();
          if (waiter) waiter(line);
          else lines.push(line);
        }
      });
      resolve({
        socket,
        send: (message) => socket.write(`${JSON.stringify(message)}\n`),
        next: () =>
          new Promise((res) => {
            if (lines.length > 0) res(lines.shift());
            else waiters.push(res);
          }),
        closed: new Promise((res) => socket.on("close", res)),
      });
    });
    socket.on("error", reject);
  });
}

test("listen creates a 0600 socket in a 0700 directory", async (t) => {
  const { service, dir } = makeService();
  t.after(() => service.close());
  const socketPath = await service.listen();
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(socketPath).mode & 0o777, 0o600);
});

test("a correct hello gets protocol, versions, token, and the probe summary", async (t) => {
  const { service } = makeService();
  t.after(() => service.close());
  const socketPath = await service.listen();
  const client = await connectClient(socketPath);
  client.send({ id: 1, method: "hello", params: { protocol: LOCAL_PROTOCOL, pluginVersion: "0.3.0-rc9" } });
  const reply = await client.next();
  assert.equal(reply.ok, true);
  assert.equal(reply.result.protocol, LOCAL_PROTOCOL);
  assert.equal(reply.result.token, TOKEN);
  assert.equal(reply.result.terminal.kittyGraphics, "verified");
  assert.equal(service.connected(), true);
  client.socket.destroy();
});

test("a protocol mismatch is refused with the upgrade hint and the connection dropped", async (t) => {
  const { service } = makeService();
  t.after(() => service.close());
  const client = await connectClient(await service.listen());
  client.send({ id: 1, method: "hello", params: { protocol: 99, pluginVersion: "9.9.9" } });
  const reply = await client.next();
  assert.equal(reply.ok, false);
  assert.equal(reply.code, "PROTOCOL_MISMATCH");
  assert.match(reply.error, /update both checkouts to the same md-viewer tag/);
  assert.equal(reply.detail.helperProtocol, LOCAL_PROTOCOL);
  await client.closed;
  assert.equal(service.connected(), false);
});

test("anything before hello is refused and dropped", async (t) => {
  const { service } = makeService();
  t.after(() => service.close());
  const client = await connectClient(await service.listen());
  client.send({ id: 1, method: "render", params: {} });
  const reply = await client.next();
  assert.equal(reply.code, "HELLO_REQUIRED");
  await client.closed;
});

test("one client at a time; the second is refused BUSY, and a departed client frees the slot", async (t) => {
  const { service } = makeService();
  t.after(() => service.close());
  const socketPath = await service.listen();
  const first = await connectClient(socketPath);
  first.send({ id: 1, method: "hello", params: { protocol: LOCAL_PROTOCOL } });
  await first.next();

  // The refusal answers the first request rather than the bare connect, so a
  // busy helper can still serve the read-only `status` query below.
  const second = await connectClient(socketPath);
  second.send({ id: 1, method: "hello", params: { protocol: LOCAL_PROTOCOL } });
  const refusal = await second.next();
  assert.equal(refusal.code, "BUSY");
  await second.closed;

  first.socket.destroy();
  await first.closed;
  // The slot frees; a new client can hello.
  await new Promise((resolve) => setTimeout(resolve, 50));
  const third = await connectClient(socketPath);
  third.send({ id: 1, method: "hello", params: { protocol: LOCAL_PROTOCOL } });
  const reply = await third.next();
  assert.equal(reply.ok, true);
  third.socket.destroy();
});

test("status answers without a hello and without disturbing an attached session", async (t) => {
  const { service } = makeService();
  service.setStatusProvider(() => ({ parser: { markerCount: 7 } }));
  t.after(() => service.close());
  const socketPath = await service.listen();

  // Unattached: a fresh connection asks and leaves; no hello anywhere.
  const probe = await connectClient(socketPath);
  probe.send({ id: 9, method: "status" });
  const idle = await probe.next();
  assert.equal(idle.ok, true);
  assert.equal(idle.result.attached, false);
  assert.equal(idle.result.helperVersion, "md-viewer-local vtest");
  assert.equal(idle.result.parser.markerCount, 7, "the provider's counters ride the answer");
  assert.equal(idle.result.token, undefined, "status never leaks the token");
  await probe.closed;

  // Attached: a second connection's status is answered instead of refused
  // BUSY, and the live session keeps its slot untouched.
  const session = await connectClient(socketPath);
  session.send({ id: 1, method: "hello", params: { protocol: LOCAL_PROTOCOL } });
  await session.next();
  const busyProbe = await connectClient(socketPath);
  busyProbe.send({ id: 2, method: "status" });
  const live = await busyProbe.next();
  assert.equal(live.ok, true);
  assert.equal(live.result.attached, true);
  await busyProbe.closed;
  assert.equal(service.connected(), true, "the attached session was not disturbed");
  session.socket.destroy();
});

test("post-hello requests route to the handler, errors carry code and detail, notifications flow back", async (t) => {
  const { service } = makeService();
  t.after(() => service.close());
  service.setRequestHandler(async (method, params) => {
    if (method === "boom") {
      const error = new Error("deliberate");
      error.code = "TEST_CODE";
      error.detail = { extra: params.x };
      throw error;
    }
    return { echoed: method, x: params.x };
  });
  const client = await connectClient(await service.listen());
  client.send({ id: 1, method: "hello", params: { protocol: LOCAL_PROTOCOL } });
  await client.next();

  client.send({ id: 2, method: "render", params: { x: 7 } });
  const ok = await client.next();
  assert.deepEqual(ok, { id: 2, ok: true, result: { echoed: "render", x: 7 } });

  client.send({ id: 3, method: "boom", params: { x: 9 } });
  const bad = await client.next();
  assert.equal(bad.ok, false);
  assert.equal(bad.code, "TEST_CODE");
  assert.deepEqual(bad.detail, { extra: 9 });

  assert.equal(service.notify("presented", { seq: 0 }), true);
  const note = await client.next();
  assert.deepEqual(note, { event: "presented", seq: 0 });
  client.socket.destroy();
});

test("without a handler, post-hello methods answer UNSUPPORTED_METHOD instead of hanging", async (t) => {
  const { service } = makeService();
  t.after(() => service.close());
  const client = await connectClient(await service.listen());
  client.send({ id: 1, method: "hello", params: { protocol: LOCAL_PROTOCOL } });
  await client.next();
  client.send({ id: 2, method: "render", params: {} });
  const reply = await client.next();
  assert.equal(reply.code, "UNSUPPORTED_METHOD");
  client.socket.destroy();
});

test("a socket path over the sun_path limit is refused with the fix in the message", async () => {
  const { service } = makeService({ dir: path.join(os.tmpdir(), "x".repeat(120)) });
  await assert.rejects(
    async () => service.listen(),
    (error) => /sun_path/.test(error.message) && /shorter/.test(error.message)
  );
});
