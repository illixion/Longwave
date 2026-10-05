'use strict';
// Finds which installed Steam app owns an executable, for the tray launcher's "Browse for a
// game…" path. A Steam game started bare usually exits at once and asks Steam to relaunch it
// (SteamAPI_RestartAppIfNecessary), which drops everything our launch set up; started with
// SteamAppId/SteamGameId in its environment, with Steam already running unelevated, it stays.
// That is the identity the PCVR host's GameLibrary gives its own titles — this is the minimal
// public equivalent, used when the host is absent or does not list the app.
//
// Paths are always handled with path.win32, so the parsing is testable off Windows. File access
// goes through an injectable `fsApi` for the same reason.
const fs = require('fs');
const path = require('path');
const { execFile, spawn } = require('child_process');

const win = path.win32;

/** Unescapes a VDF quoted string body (Steam writes backslashes doubled). */
function vdfUnescape(s) {
  return s.replace(/\\(.)/g, (_m, c) => (c === 'n' ? '\n' : c === 't' ? '\t' : c));
}

/** Every value of `key` in a text VDF/ACF file, in order. Keys match case-insensitively. */
function vdfValues(text, key) {
  const out = [];
  const re = /"((?:[^"\\]|\\.)*)"\s+"((?:[^"\\]|\\.)*)"/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    if (vdfUnescape(m[1]).toLowerCase() === key.toLowerCase()) out.push(vdfUnescape(m[2]));
  }
  return out;
}

/** Library roots listed in steamapps\libraryfolders.vdf (both the old and the new layout). */
function parseLibraryFolders(text) {
  const paths = vdfValues(text, 'path');
  if (paths.length > 0) return paths;
  // Pre-2021 layout: "1" "D:\\SteamLibrary" directly under "LibraryFolders".
  // One key/value pair per line, and the value must look like a path — otherwise a value of
  // "1" followed by the next line's key reads as a pair.
  const re = /^[ \t]*"(\d+)"[ \t]+"((?:[^"\\]|\\.)*)"[ \t]*$/gm;
  const old = [];
  let m;
  while ((m = re.exec(text)) !== null) {
    const value = vdfUnescape(m[2]);
    if (/^[a-z]:\\/i.test(value)) old.push(value);
  }
  return old;
}

/** { appId, name, installDir } from an appmanifest_*.acf, or null. */
function parseAppManifest(text) {
  const appId = vdfValues(text, 'appid')[0];
  const name = vdfValues(text, 'name')[0];
  const installDir = vdfValues(text, 'installdir')[0];
  if (!appId || !/^\d+$/.test(appId) || !installDir) return null;
  return { appId: Number(appId), name: name || installDir, installDir };
}

const defaultFs = {
  existsSync: (p) => fs.existsSync(p),
  readFileSync: (p) => fs.readFileSync(p, 'utf8'),
  readdirSync: (p) => fs.readdirSync(p),
};

/** The Steam root plus every library it lists, de-duplicated case-insensitively. */
function steamLibraries(steamRoot, fsApi = defaultFs) {
  if (!steamRoot) return [];
  const libraries = [win.normalize(steamRoot)];
  const vdf = win.join(steamRoot, 'steamapps', 'libraryfolders.vdf');
  try {
    if (fsApi.existsSync(vdf)) libraries.push(...parseLibraryFolders(fsApi.readFileSync(vdf)).map((p) => win.normalize(p)));
  } catch { /* the root library alone still works */ }
  const seen = new Set();
  return libraries.filter((p) => {
    const key = p.toLowerCase().replace(/\\+$/, '');
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

// SteamVR and the redistributables are tools, not games: never give a browsed exe their identity
// (mirrors GameLibrary.UnsupportedSteamAppIds).
const NON_GAME_APP_IDS = new Set([250820, 228980]);

/**
 * The Steam app whose install directory contains `exePath`, or null. Matches
 * <library>\steamapps\common\<installdir>\… against each library's appmanifest installdir.
 */
function findOwningSteamApp(exePath, steamRoot, fsApi = defaultFs) {
  if (!exePath || !steamRoot) return null;
  const full = win.normalize(exePath);
  for (const library of steamLibraries(steamRoot, fsApi)) {
    const steamapps = win.join(library, 'steamapps');
    const common = win.join(steamapps, 'common') + win.sep;
    if (!full.toLowerCase().startsWith(common.toLowerCase())) continue;
    const dirName = full.slice(common.length).split(win.sep)[0];
    if (!dirName) continue;
    let manifests;
    try {
      manifests = fsApi.readdirSync(steamapps).filter((f) => /^appmanifest_\d+\.acf$/i.test(f));
    } catch {
      continue;
    }
    for (const file of manifests) {
      let app;
      try { app = parseAppManifest(fsApi.readFileSync(win.join(steamapps, file))); } catch { app = null; }
      if (app && !NON_GAME_APP_IDS.has(app.appId)
          && app.installDir.toLowerCase() === dirName.toLowerCase()) {
        return { ...app, installDir: win.join(common, app.installDir) };
      }
    }
  }
  return null;
}

/** First value of a `reg query` result, or null. */
function regQuery(key, value) {
  return new Promise((resolve) => {
    execFile('reg', ['query', key, '/v', value], { windowsHide: true }, (err, stdout) => {
      if (err) return resolve(null);
      const m = String(stdout).match(new RegExp(`${value}\\s+REG_\\w+\\s+(.+)`, 'i'));
      resolve(m ? m[1].trim() : null);
    });
  });
}

/** Steam's install directory, from the registry (Steam is often moved), or null. */
async function findSteamRoot(fsApi = defaultFs) {
  const candidates = [
    await regQuery('HKCU\\Software\\Valve\\Steam', 'SteamPath'),
    await regQuery('HKLM\\SOFTWARE\\WOW6432Node\\Valve\\Steam', 'InstallPath'),
    'C:\\Program Files (x86)\\Steam',
  ].filter(Boolean).map((p) => win.normalize(p));
  return candidates.find((p) => fsApi.existsSync(win.join(p, 'steam.exe'))) || null;
}

function isSteamRunning() {
  return new Promise((resolve) => {
    execFile('tasklist', ['/FI', 'IMAGENAME eq steam.exe', '/NH'], { windowsHide: true },
      (err, stdout) => resolve(!err && /steam\.exe/i.test(String(stdout))));
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Starts Steam (silently, as the current user — this app is asInvoker, so never elevated) if it
 * is not running, and waits for it, as GameLibrary.EnsureSteamRunningAsync does: up to 30 s for
 * the process, then 2 s more before a Steamworks client can attach. Resolves true when it runs.
 */
async function ensureSteamRunning(steamRoot, log = () => {}) {
  if (await isSteamRunning()) return true;
  const exe = steamRoot && win.join(steamRoot, 'steam.exe');
  if (!exe || !fs.existsSync(exe)) return false;
  log('Steam is not running; starting it first');
  try {
    spawn(exe, ['-silent'], { detached: true, stdio: 'ignore', cwd: steamRoot }).unref();
  } catch {
    return false;
  }
  for (let i = 0; i < 60; i++) {
    await sleep(500);
    if (await isSteamRunning()) {
      await sleep(2000);
      return true;
    }
  }
  return false;
}

module.exports = {
  parseLibraryFolders,
  parseAppManifest,
  steamLibraries,
  findOwningSteamApp,
  findSteamRoot,
  ensureSteamRunning,
};
