import path from "node:path";

// Pure, dependency-injected Chromium discovery: platform, environment, and a
// file-existence predicate are all arguments so every branch is unit-testable
// on any host OS without touching the real filesystem. Never invokes
// `playwright install` and never downloads a browser — it only looks for an
// executable that is already present.

const MAC_KNOWN_APPS = [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
];

const MAC_HOMEBREW_PREFIXES = ["/opt/homebrew", "/usr/local"];
const MAC_HOMEBREW_BIN_NAMES = ["google-chrome", "chromium", "microsoft-edge"];

const MAC_USER_APP_SUFFIXES = [
  "Google Chrome.app/Contents/MacOS/Google Chrome",
  "Chromium.app/Contents/MacOS/Chromium",
  "Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
];

const LINUX_PATH_NAMES = [
  "google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
  "microsoft-edge", "microsoft-edge-stable",
];

const LINUX_FIXED_DIRS = ["/usr/bin", "/usr/local/bin", "/snap/bin"];

const LINUX_FLATPAK_SYSTEM = [
  "/var/lib/flatpak/exports/bin/com.google.Chrome",
  "/var/lib/flatpak/exports/bin/org.chromium.Chromium",
  "/var/lib/flatpak/exports/bin/com.microsoft.Edge",
];

const LINUX_FLATPAK_USER_SUFFIXES = [
  ".local/share/flatpak/exports/bin/com.google.Chrome",
  ".local/share/flatpak/exports/bin/org.chromium.Chromium",
  ".local/share/flatpak/exports/bin/com.microsoft.Edge",
];

const WINDOWS_PATH_NAMES = ["chrome", "msedge", "chromium"];

const WINDOWS_PROGRAM_FILES_SUFFIXES = [
  ["Google", "Chrome", "Application", "chrome.exe"],
  ["Microsoft", "Edge", "Application", "msedge.exe"],
  ["Chromium", "Application", "chrome.exe"],
];

const WINDOWS_LOCALAPPDATA_SUFFIXES = [
  ["Google", "Chrome", "Application", "chrome.exe"],
  ["Microsoft", "Edge", "Application", "msedge.exe"],
];

function pathEntries(env, win32) {
  const raw = win32 ? (env.Path ?? env.PATH ?? "") : (env.PATH ?? "");
  return raw.split(win32 ? ";" : ":").filter(Boolean);
}

function windowsPathCandidates(env, names) {
  const extensions = (env.PATHEXT || ".EXE;.CMD;.BAT;.COM").split(";").filter(Boolean);
  const candidates = [];
  for (const dir of pathEntries(env, true)) {
    for (const name of names) {
      for (const ext of extensions) {
        candidates.push(path.win32.join(dir, name + ext));
      }
    }
  }
  return candidates;
}

function posixPathCandidates(env, names) {
  const candidates = [];
  for (const dir of pathEntries(env, false)) {
    for (const name of names) candidates.push(path.posix.join(dir, name));
  }
  return candidates;
}

function actionableError(platform, searched) {
  const list = searched.length > 0 ? searched.join(", ") : "(nothing — no search locations applied)";
  return `no approved Chrome, Chromium, or Edge executable found for platform "${platform}". `
    + `Searched ${searched.length} location(s): ${list}. `
    + `Set browser.executable_path in your md-viewer config to an installed browser.`;
}

/**
 * @param {string} platform - Node's `process.platform` ("darwin" | "linux" | "win32")
 * @param {Record<string, string>} env - environment variables to search
 * @param {(candidate: string) => boolean} exists - file-existence predicate
 * @param {{ executable_path?: string }} [options]
 * @returns {{ executable: string, reason: string }}
 */
export function discoverChromium(platform, env, exists, options = {}) {
  if (options.executable_path) {
    if (!exists(options.executable_path)) {
      throw new Error(`configured Chromium does not exist: ${options.executable_path}`);
    }
    return { executable: options.executable_path, reason: "explicit executable_path" };
  }

  const searched = [];
  const attempt = (candidate, reason) => {
    searched.push(candidate);
    return exists(candidate) ? { executable: candidate, reason } : null;
  };

  if (platform === "darwin") {
    for (const candidate of MAC_KNOWN_APPS) {
      const hit = attempt(candidate, "known macOS application path");
      if (hit) return hit;
    }
    for (const prefix of MAC_HOMEBREW_PREFIXES) {
      for (const name of MAC_HOMEBREW_BIN_NAMES) {
        const hit = attempt(path.posix.join(prefix, "bin", name), `Homebrew binary (${prefix}/bin)`);
        if (hit) return hit;
      }
    }
    if (env.HOME) {
      for (const suffix of MAC_USER_APP_SUFFIXES) {
        const hit = attempt(path.posix.join(env.HOME, "Applications", suffix), "user Applications directory");
        if (hit) return hit;
      }
    }
    throw new Error(actionableError(platform, searched));
  }

  if (platform === "linux") {
    for (const candidate of posixPathCandidates(env, LINUX_PATH_NAMES)) {
      const hit = attempt(candidate, "found on PATH");
      if (hit) return hit;
    }
    for (const dir of LINUX_FIXED_DIRS) {
      for (const name of LINUX_PATH_NAMES) {
        const hit = attempt(path.posix.join(dir, name), "known Linux binary directory");
        if (hit) return hit;
      }
    }
    for (const candidate of LINUX_FLATPAK_SYSTEM) {
      const hit = attempt(candidate, "Flatpak system export");
      if (hit) return hit;
    }
    if (env.HOME) {
      for (const suffix of LINUX_FLATPAK_USER_SUFFIXES) {
        const hit = attempt(path.posix.join(env.HOME, suffix), "Flatpak user export");
        if (hit) return hit;
      }
    }
    throw new Error(actionableError(platform, searched));
  }

  if (platform === "win32") {
    for (const candidate of windowsPathCandidates(env, WINDOWS_PATH_NAMES)) {
      const hit = attempt(candidate, "found on PATH");
      if (hit) return hit;
    }
    for (const root of [env["PROGRAMFILES"], env["PROGRAMFILES(X86)"]].filter(Boolean)) {
      for (const suffix of WINDOWS_PROGRAM_FILES_SUFFIXES) {
        const hit = attempt(path.win32.join(root, ...suffix), "Program Files");
        if (hit) return hit;
      }
    }
    if (env.LOCALAPPDATA) {
      for (const suffix of WINDOWS_LOCALAPPDATA_SUFFIXES) {
        const hit = attempt(path.win32.join(env.LOCALAPPDATA, ...suffix), "LOCALAPPDATA");
        if (hit) return hit;
      }
    }
    throw new Error(actionableError(platform, searched));
  }

  throw new Error(`Chromium discovery does not support platform "${platform}"`);
}
