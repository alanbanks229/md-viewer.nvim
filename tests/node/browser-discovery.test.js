import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

function existsAmong(paths) {
  const set = new Set(paths);
  return (candidate) => set.has(candidate);
}

test("explicit executable_path always wins, on any platform", () => {
  const exists = existsAmong(["/custom/chrome"]);
  const result = discoverChromium("linux", {}, exists, { executable_path: "/custom/chrome" });
  assert.deepEqual(result, { executable: "/custom/chrome", reason: "explicit executable_path" });
});

test("explicit missing executable_path throws an actionable error", () => {
  const exists = existsAmong([]);
  assert.throws(
    () => discoverChromium("darwin", {}, exists, { executable_path: "/definitely/missing/chrome" }),
    /configured Chromium does not exist: \/definitely\/missing\/chrome/,
  );
});

test("macOS: finds the second known application path when the first is absent", () => {
  const exists = existsAmong(["/Applications/Chromium.app/Contents/MacOS/Chromium"]);
  const result = discoverChromium("darwin", {}, exists, {});
  assert.equal(result.executable, "/Applications/Chromium.app/Contents/MacOS/Chromium");
  assert.equal(result.reason, "known macOS application path");
});

test("macOS: falls back to Homebrew bin directories", () => {
  const exists = existsAmong(["/opt/homebrew/bin/chromium"]);
  const result = discoverChromium("darwin", {}, exists, {});
  assert.equal(result.executable, "/opt/homebrew/bin/chromium");
  assert.match(result.reason, /Homebrew/);
});

test("macOS: falls back to a user ~/Applications equivalent", () => {
  const env = { HOME: "/Users/alice" };
  const target = "/Users/alice/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
  const exists = existsAmong([target]);
  const result = discoverChromium("darwin", env, exists, {});
  assert.equal(result.executable, target);
  assert.match(result.reason, /user Applications/);
});

test("macOS: not found throws an actionable error listing every searched location", () => {
  const env = { HOME: "/Users/alice" };
  const exists = existsAmong([]);
  assert.throws(() => discoverChromium("darwin", env, exists, {}), (err) => {
    assert.match(err.message, /darwin/);
    assert.match(err.message, /Applications\/Google Chrome\.app/);
    assert.match(err.message, /opt\/homebrew\/bin/);
    assert.match(err.message, /Users\/alice\/Applications/);
    assert.match(err.message, /Searched \d+ location/);
    return true;
  });
});

test("Linux: finds a browser on PATH before checking fixed directories", () => {
  const env = { PATH: "/home/alice/bin:/usr/bin" };
  const exists = existsAmong(["/home/alice/bin/chromium-browser", "/usr/bin/google-chrome"]);
  const result = discoverChromium("linux", env, exists, {});
  assert.equal(result.executable, "/home/alice/bin/chromium-browser");
  assert.equal(result.reason, "found on PATH");
});

test("Linux: falls back to known fixed directories when PATH has nothing", () => {
  const env = { PATH: "/home/alice/bin" };
  const exists = existsAmong(["/usr/bin/chromium"]);
  const result = discoverChromium("linux", env, exists, {});
  assert.equal(result.executable, "/usr/bin/chromium");
  assert.equal(result.reason, "known Linux binary directory");
});

test("Linux: falls back to a system Flatpak export", () => {
  const env = {};
  const exists = existsAmong(["/var/lib/flatpak/exports/bin/org.chromium.Chromium"]);
  const result = discoverChromium("linux", env, exists, {});
  assert.equal(result.executable, "/var/lib/flatpak/exports/bin/org.chromium.Chromium");
  assert.match(result.reason, /Flatpak system/);
});

test("Linux: falls back to a per-user Flatpak export", () => {
  const env = { HOME: "/home/alice" };
  const target = "/home/alice/.local/share/flatpak/exports/bin/com.google.Chrome";
  const exists = existsAmong([target]);
  const result = discoverChromium("linux", env, exists, {});
  assert.equal(result.executable, target);
  assert.match(result.reason, /Flatpak user/);
});

test("Linux: not found throws an actionable error", () => {
  const env = { PATH: "/usr/bin" };
  const exists = existsAmong([]);
  assert.throws(() => discoverChromium("linux", env, exists, {}), (err) => {
    assert.match(err.message, /linux/);
    assert.match(err.message, /Searched \d+ location/);
    return true;
  });
});

test("Windows: PATH search honours PATHEXT to find chrome.exe", () => {
  const env = { Path: "C:\\Users\\alice\\bin", PATHEXT: ".COM;.EXE;.BAT" };
  const target = path.win32.join("C:\\Users\\alice\\bin", "chrome.EXE");
  const exists = existsAmong([target]);
  const result = discoverChromium("win32", env, exists, {});
  assert.equal(result.executable, target);
  assert.equal(result.reason, "found on PATH");
});

test("Windows: falls back to Program Files", () => {
  const env = { PROGRAMFILES: "C:\\Program Files" };
  const target = path.win32.join("C:\\Program Files", "Google", "Chrome", "Application", "chrome.exe");
  const exists = existsAmong([target]);
  const result = discoverChromium("win32", env, exists, {});
  assert.equal(result.executable, target);
  assert.equal(result.reason, "Program Files");
});

test("Windows: falls back to LOCALAPPDATA", () => {
  const env = { LOCALAPPDATA: "C:\\Users\\alice\\AppData\\Local" };
  const target = path.win32.join(env.LOCALAPPDATA, "Microsoft", "Edge", "Application", "msedge.exe");
  const exists = existsAmong([target]);
  const result = discoverChromium("win32", env, exists, {});
  assert.equal(result.executable, target);
  assert.equal(result.reason, "LOCALAPPDATA");
});

test("Windows: not found throws an actionable error naming the platform", () => {
  const env = {};
  const exists = existsAmong([]);
  assert.throws(() => discoverChromium("win32", env, exists, {}), (err) => {
    assert.match(err.message, /win32/);
    assert.match(err.message, /Searched \d+ location/);
    return true;
  });
});

test("unsupported platforms throw rather than silently returning nothing", () => {
  assert.throws(() => discoverChromium("freebsd", {}, existsAmong([]), {}), /does not support platform/);
});
