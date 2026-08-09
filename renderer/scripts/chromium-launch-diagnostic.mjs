// TEMPORARY CI diagnostic for the macos-latest hang. Not part of the test
// suite. Runs the exact browser lifecycle browser.js performs -- launch,
// context, page, setContent, evaluate, CDP screenshot, close -- across several
// browser builds and launch-argument sets, with a per-phase watchdog, so a
// hung run reports *which phase* of *which configuration* wedged instead of
// producing twenty minutes of silence.

import { execSync } from "node:child_process";
import fs from "node:fs";
import { chromium } from "playwright";

const PHASE_TIMEOUT_MS = 25000;
const ITERATIONS = Number(process.env.DIAG_ITERATIONS ?? 12);

const CHROME_STABLE = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const CHROME_FOR_TESTING =
  "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";

const PRODUCTION_ARGS = [
  "--disable-extensions",
  "--disable-component-update",
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-frame-rate-limit",
];
const WITHOUT_FRAME_RATE_FLAG = PRODUCTION_ARGS.filter((a) => a !== "--disable-frame-rate-limit");

const CONFIGS = [
  { name: "chrome-stable + production args", executable: CHROME_STABLE, args: PRODUCTION_ARGS },
  { name: "chrome-stable, no --disable-frame-rate-limit", executable: CHROME_STABLE, args: WITHOUT_FRAME_RATE_FLAG },
  { name: "chrome-for-testing + production args", executable: CHROME_FOR_TESTING, args: PRODUCTION_ARGS },
];

const HTML =
  "<!doctype html><html><head><meta charset=utf-8></head>"
  + "<body><h1>Heading</h1><p>body</p></body></html>";

class Wedged extends Error {}

/// Bound one await. The underlying operation is left running -- the point is to
/// keep reporting after a wedge, not to clean up after it.
async function phase(label, fn) {
  const started = performance.now();
  let timer;
  const watchdog = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Wedged(label)), PHASE_TIMEOUT_MS);
  });
  try {
    const value = await Promise.race([fn(), watchdog]);
    return { value, ms: Math.round(performance.now() - started) };
  } finally {
    clearTimeout(timer);
  }
}

async function oneIteration(config) {
  const timings = [];
  const record = async (label, fn) => {
    const { value, ms } = await phase(label, fn);
    timings.push(`${label}=${ms}ms`);
    return value;
  };

  const browser = await record("launch", () =>
    chromium.launch({ executablePath: config.executable, headless: true, timeout: 10000, args: config.args })
  );
  try {
    const context = await record("newContext", () =>
      browser.newContext({ deviceScaleFactor: 2, javaScriptEnabled: false })
    );
    const page = await record("newPage", () => context.newPage());
    const cdp = await record("newCDPSession", () => context.newCDPSession(page));
    await record("setViewportSize", () => page.setViewportSize({ width: 640, height: 480 }));
    await record("setContent", () => page.setContent(HTML, { waitUntil: "domcontentloaded" }));
    await record("evaluate", () => page.evaluate(() => document.documentElement.scrollHeight));
    await record("cdpCaptureScreenshot", () =>
      cdp.send("Page.captureScreenshot", {
        format: "png",
        optimizeForSpeed: true,
        captureBeyondViewport: false,
        clip: { x: 0, y: 0, width: 640, height: 480, scale: 2 },
      })
    );
    await record("playwrightScreenshot", () =>
      page.screenshot({ type: "png", fullPage: false, animations: "disabled", scale: "device" })
    );
    await record("closeContext", () => context.close());
  } finally {
    await phase("closeBrowser", () => browser.close()).catch(() => {});
  }
  return timings.join(" ");
}

function reap() {
  for (const pattern of ["Google Chrome for Testing", "Google Chrome", "chrome_crashpad"]) {
    try {
      execSync(`pkill -f ${JSON.stringify(pattern)}`, { stdio: "ignore" });
    } catch {}
  }
}

const summary = [];

for (const config of CONFIGS) {
  if (!fs.existsSync(config.executable)) {
    console.log(`\n### ${config.name}\n  SKIPPED — ${config.executable} does not exist`);
    summary.push(`SKIP  ${config.name}`);
    continue;
  }
  console.log(`\n### ${config.name}\n  ${config.executable}\n  args: ${config.args.join(" ")}`);
  let wedgedAt = null;
  let completed = 0;
  for (let i = 1; i <= ITERATIONS; i += 1) {
    try {
      const timings = await oneIteration(config);
      completed += 1;
      console.log(`  iteration ${i}: ok — ${timings}`);
    } catch (error) {
      if (error instanceof Wedged) {
        wedgedAt = `iteration ${i}, phase "${error.message}"`;
        console.log(`  iteration ${i}: WEDGED in phase "${error.message}" after ${PHASE_TIMEOUT_MS}ms`);
      } else {
        wedgedAt = `iteration ${i}, error ${error?.message ?? error}`;
        console.log(`  iteration ${i}: ERROR — ${error?.stack ?? error}`);
      }
      break;
    }
  }
  summary.push(
    wedgedAt
      ? `HANG  ${config.name} — ${completed}/${ITERATIONS} ok, then ${wedgedAt}`
      : `OK    ${config.name} — ${completed}/${ITERATIONS} iterations`
  );
  reap();
}

console.log("\n=== summary ===");
for (const line of summary) console.log(line);

// A wedged browser keeps handles open; never let this script itself hang.
process.exit(0);
