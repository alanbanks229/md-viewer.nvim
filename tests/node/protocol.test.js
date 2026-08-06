import test from "node:test";
import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { once } from "node:events";
import { LineProtocol } from "../../renderer/src/protocol.js";

test("returns IDs and rejects malformed requests", async () => {
  const input = new PassThrough(); const output = new PassThrough();
  const protocol = new LineProtocol(input, output, async (request) => ({ method: request.method }));
  protocol.start();
  input.write('{"id":9,"method":"health","params":{}}\n');
  const [valid] = await once(output, "data");
  assert.deepEqual(JSON.parse(valid.toString()), { id: 9, ok: true, result: { method: "health" } });
  input.write("not json\n");
  const [invalid] = await once(output, "data");
  const response = JSON.parse(invalid.toString());
  assert.equal(response.id, -1); assert.equal(response.ok, false);
  protocol.reader.close();
});
