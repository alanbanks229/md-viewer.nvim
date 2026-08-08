// One line per probe run: how fast it grew, whether it finished, and what it
// looked like once the writing stopped. Designed to be read as a table when
// matrix.sh calls it repeatedly.
//
//   node growth.mjs <out-dir> [label]
import fs from "node:fs";
import path from "node:path";

const dir = process.argv[2];
const label = process.argv[3] ?? path.basename(dir ?? "");
const trailPath = path.join(dir ?? "", "samples.jsonl");
const mb = (kb) => (Number.isFinite(kb) ? kb / 1024 : NaN);

if (!fs.existsSync(trailPath)) {
  console.log(`${label.padEnd(18)} no data`);
  process.exit(0);
}
const rows = fs
  .readFileSync(trailPath, "utf8")
  .split("\n")
  .filter(Boolean)
  .map((line) => JSON.parse(line));

const at = (name) => rows.find((r) => r.kind === "mark" && r.label === name)?.rss_kb;
const samples = rows.filter((r) => r.kind === "sample");
const idles = rows.filter((r) => r.kind === "idle");

const start = at("after_transmit") ?? at("after_base_image") ?? at("baseline");
const last = samples[samples.length - 1];
const frames = last ? last.frame : 0;
const perFrame = last && frames > 0 ? (last.rss_kb - start) / frames : NaN;
const finished = fs.existsSync(path.join(dir, "result.json"));
const aborted = finished ? JSON.parse(fs.readFileSync(path.join(dir, "result.json"), "utf8")).aborted : null;

// What the number does once nothing is being sent is the difference between a
// backlog and a retention.
const idleDrift = idles.length > 1 ? mb(idles[idles.length - 1].rss_kb - idles[0].rss_kb) : NaN;
const afterDeleteAll = at("after_delete_all");
const afterClear = at("after_clear_screen");

console.log(
  label.padEnd(18) +
    `start ${mb(start).toFixed(0).padStart(5)}M` +
    `  frames ${String(frames).padStart(4)}` +
    `  ${(perFrame / 1024).toFixed(2).padStart(7)} MB/frame` +
    `  end ${mb(last?.rss_kb).toFixed(0).padStart(5)}M` +
    (Number.isFinite(idleDrift) ? `  idle drift ${idleDrift.toFixed(0).padStart(5)}M` : "  idle drift     -") +
    (afterDeleteAll ? `  after d=A ${mb(afterDeleteAll).toFixed(0).padStart(5)}M` : "") +
    (afterClear ? `  cleared ${mb(afterClear).toFixed(0).padStart(5)}M` : "") +
    (aborted ? "  ABORTED" : finished ? "" : "  KILLED")
);
