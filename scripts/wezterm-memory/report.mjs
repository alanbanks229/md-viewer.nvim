// Print one probe run, or compare several. Separate from run.sh so a run can be
// re-read without re-running it.
//
//   node report.mjs <out-dir> [<out-dir> ...]
import fs from "node:fs";
import path from "node:path";

const dirs = process.argv.slice(2);
if (dirs.length === 0) {
  console.error("usage: report.mjs <out-dir> [...]");
  process.exit(2);
}

const mb = (kb) => (Number.isFinite(kb) ? (kb / 1024).toFixed(0) : "?");

for (const dir of dirs) {
  const file = path.join(dir, "result.json");
  const trail = path.join(dir, "samples.jsonl");
  let r;
  if (fs.existsSync(file)) {
    r = JSON.parse(fs.readFileSync(file, "utf8"));
  } else if (fs.existsSync(trail)) {
    // A run killed from outside never writes result.json; the trail is all
    // there is, and for a runaway it is the only interesting part anyway.
    const rows = fs
      .readFileSync(trail, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line));
    r = {
      case: "?",
      description: "(incomplete run, recovered from samples.jsonl)",
      notes: ["run did not finish; no result.json"],
      marks: rows.filter((x) => x.kind === "mark"),
      samples: rows.filter((x) => x.kind === "sample"),
    };
  } else {
    console.log(`\n${path.basename(dir)}: no result.json and no samples.jsonl`);
    continue;
  }
  const build = fs.existsSync(path.join(dir, "build.txt"))
    ? fs.readFileSync(path.join(dir, "build.txt"), "utf8").trim()
    : "?";
  console.log(`\n${path.basename(dir)}  [${build}]  case ${r.case}`);
  console.log(`  ${r.description}`);
  for (const note of r.notes ?? []) console.log(`  note: ${note}`);
  if (r.aborted) console.log(`  ABORTED: ${r.aborted}`);

  const base = r.marks?.find((m) => m.label === "baseline")?.rss_kb ?? NaN;
  console.log("\n  mark                        RSS MB   delta MB");
  for (const m of r.marks ?? []) {
    console.log(
      "  " + m.label.padEnd(28) + mb(m.rss_kb).padStart(6) + mb(m.rss_kb - base).padStart(11)
    );
  }

  const s = r.samples ?? [];
  if (s.length > 2) {
    // Linear growth and a plateau look identical over four seconds. Compare the
    // slope of the first third against the last third: a leak keeps its slope,
    // a cache loses it.
    const third = Math.floor(s.length / 3);
    const slope = (a, b) => {
      const dt = (b.t_ms - a.t_ms) / 1000;
      return dt > 0 ? (b.rss_kb - a.rss_kb) / 1024 / dt : 0;
    };
    const early = slope(s[0], s[third]);
    const late = slope(s[s.length - 1 - third], s[s.length - 1]);
    const perFrame = (s[s.length - 1].rss_kb - s[0].rss_kb) / Math.max(1, s[s.length - 1].frame - s[0].frame);
    console.log(
      `\n  frames ${s[0].frame}..${s[s.length - 1].frame}   ` +
        `growth ${mb(s[s.length - 1].rss_kb - s[0].rss_kb)} MB   ` +
        `${perFrame.toFixed(1)} KB/frame`
    );
    console.log(
      `  slope: first third ${early.toFixed(1)} MB/s, last third ${late.toFixed(1)} MB/s  ` +
        `-> ${late > early * 0.6 ? "still climbing" : "flattening"}`
    );
  }

  const summary = path.join(dir, "vmmap-peak.txt");
  if (fs.existsSync(summary)) {
    const base = fs.existsSync(path.join(dir, "vmmap-baseline.txt"))
      ? fs.readFileSync(path.join(dir, "vmmap-baseline.txt"), "utf8")
      : "";
    const parse = (text) => {
      const rows = new Map();
      for (const line of text.split("\n")) {
        // "REGION TYPE   VIRTUAL   RESIDENT   DIRTY   SWAPPED  VOLATILE ..."
        const m = line.match(/^(\S[^0-9]*?)\s{2,}([\d.]+[KMG]?)\s+([\d.]+[KMG]?)\s+([\d.]+[KMG]?)/);
        if (!m) continue;
        const scale = { K: 1, M: 1024, G: 1024 * 1024 };
        const kb = (v) => {
          const unit = v.slice(-1);
          return scale[unit] ? parseFloat(v) * scale[unit] : parseFloat(v) / 1024;
        };
        rows.set(m[1].trim(), kb(m[3]));
      }
      return rows;
    };
    const before = parse(base);
    const after = parse(fs.readFileSync(summary, "utf8"));
    const deltas = [...after.entries()]
      .map(([k, v]) => [k, v - (before.get(k) ?? 0)])
      .filter(([, d]) => Math.abs(d) > 4096)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 8);
    if (deltas.length) {
      console.log("\n  vmmap resident growth, baseline -> peak (MB):");
      for (const [region, d] of deltas) console.log("    " + region.padEnd(34) + mb(d).padStart(7));
    }
  }
}
console.log("");
