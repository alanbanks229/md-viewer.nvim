import readline from "node:readline";

export class LineProtocol {
  constructor(input, output, onRequest) {
    this.output = output;
    this.onRequest = onRequest;
    this.reader = readline.createInterface({ input, crlfDelay: Infinity });
  }

  send(message) {
    this.output.write(`${JSON.stringify(message)}\n`);
  }

  start() {
    this.reader.on("line", async (line) => {
      let request;
      try {
        request = JSON.parse(line);
        if (!Number.isInteger(request.id) || typeof request.method !== "string") {
          throw new Error("request must contain an integer id and string method");
        }
      } catch (error) {
        this.send({ id: request?.id ?? -1, ok: false, error: `invalid request: ${error.message}` });
        return;
      }
      try {
        const result = await this.onRequest(request);
        this.send({ id: request.id, ok: true, result });
      } catch (error) {
        this.send({ id: request.id, ok: false, error: error.message, code: error.code ?? "RENDER_ERROR" });
      }
    });
  }
}
