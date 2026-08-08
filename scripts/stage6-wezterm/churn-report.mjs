// Render one churn run as a table. Kept separate from churn.sh so a run can be
// re-read without re-running it.
import fs from "node:fs";
import path from "node:path";

const out = process.argv[2];
if (!out) {
  console.error("usage: churn-report.mjs <out-dir>");
  process.exit(2);
}
const run = JSON.parse(fs.readFileSync(path.join(out, "churn.json"), "utf8"));
const cpuFile = path.join(out, "cpu.txt");
const cpu = fs.existsSync(cpuFile)
  ? fs
      .readFileSync(cpuFile, "utf8")
      .split("\n")
      .map(Number)
      .filter((n) => Number.isFinite(n) && n > 0)
  : [];

const kb = (n) => (n / 1024).toFixed(1);
console.log(
  `\nWezTerm ${run.build}  profile=${run.profile}  encoding=${run.encoding}  ` +
    `grid ${run.grid.cols}x${run.grid.rows}  cell ${run.cell.width}x${run.cell.height}  ${run.rects} rectangles`
);
console.log(
  "\n  workload                                                     frames   B/frame   placed  kept  deleted   ms mean   ms worst"
);
for (const s of run.samples) {
  console.log(
    "  " +
      s.workload.padEnd(58) +
      String(s.frames).padStart(6) +
      (s.bytes_per_frame > 4096 ? `${kb(s.bytes_per_frame)}K` : Math.round(s.bytes_per_frame)).toString().padStart(10) +
      (s.placements_per_frame === undefined ? "-" : s.placements_per_frame.toFixed(1)).padStart(9) +
      (s.kept_per_frame === undefined ? "-" : s.kept_per_frame.toFixed(1)).padStart(6) +
      (s.deletions_per_frame === undefined ? "-" : s.deletions_per_frame.toFixed(1)).padStart(9) +
      s.ms_mean.toFixed(2).padStart(10) +
      s.ms_worst.toFixed(2).padStart(11)
  );
}

if (cpu.length) {
  const sorted = [...cpu].sort((a, b) => a - b);
  console.log(
    `\n  terminal CPU over ${cpu.length}s: median ${sorted[Math.floor(sorted.length / 2)].toFixed(1)}%, ` +
      `p90 ${sorted[Math.floor(sorted.length * 0.9)].toFixed(1)}%, peak ${sorted[sorted.length - 1].toFixed(1)}%`
  );
}

// The number that decides it: a drag frame has to fit inside the ~25ms budget
// stage 2 established, and has to beat the path it replaces.
const drag = run.samples.find((s) => s.workload.startsWith("diff"));
if (drag) {
  console.log(
    `\n  a real drag frame: ${Math.round(drag.bytes_per_frame)} B and ${drag.ms_mean.toFixed(2)} ms ` +
      `(budget is ~25 ms at the 40fps stage 2 established)`
  );
}
console.log("");
