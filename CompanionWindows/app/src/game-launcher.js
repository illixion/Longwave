'use strict';
// Pure parts of the tray launcher ("Launch game…", NATIVE_V3_PROTOCOL.md §7.6): the first-use
// consent text and its stored answer, the recents list, the command-line game argument, and the
// decisions about what a picked file is and how it starts. No Electron in here, so `npm test`
// covers it; main.js does the dialogs, the windows and the actual launching.
const fs = require('fs');
const path = require('path');

const win = path.win32;

const CONSENT_FILE = 'launch-consent.json';
const RECENTS_FILE = 'launch-recents.json';
const MAX_RECENTS = 6;
const LAUNCHABLE_EXTENSIONS = ['.exe', '.lnk', '.url'];

// ---- First-use consent ---------------------------------------------------

/**
 * What a launch through Longwave does, one plain-language line each — the consent box lists them.
 * This list is the one place to change when the launcher gains something: the game audio
 * component (v3 audio channel, §4.4) adds its sentence here, e.g. "loads Longwave's audio
 * component into games without anti-cheat; games with anti-cheat start without it".
 */
const LAUNCH_EFFECTS = [
  'starts the game as you, never as administrator',
  "applies Longwave's optimised launch profile for the title, when it has one",
  'starts it in VR through PCVR while a PCVR session is on, otherwise on the desktop',
  'gives a Steam game its Steam identity, so Steam does not restart it',
];

function consentMessageOptions() {
  return {
    type: 'question',
    title: 'Launch game',
    message: 'Launch this game through Longwave?',
    detail: 'Launching through Longwave:\n'
      + LAUNCH_EFFECTS.map((line) => `•  ${line}`).join('\n')
      + '\n\nGames you start any other way are not affected.',
    buttons: ['Yes', 'No'],
    defaultId: 0,
    cancelId: 1,
    noLink: true,
    checkboxLabel: "Don't ask again",
    checkboxChecked: false,
  };
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2));
  fs.renameSync(tmp, file);
}

/** True when the user said Yes with "Don't ask again" ticked. Deleting the file re-asks. */
function consentRemembered(userData) {
  return readJson(path.join(userData, CONSENT_FILE))?.dontAsk === true;
}

function setConsentRemembered(userData, remembered) {
  const file = path.join(userData, CONSENT_FILE);
  if (remembered) writeJson(file, { dontAsk: true, decidedAt: new Date().toISOString() });
  else fs.rmSync(file, { force: true });
}

/**
 * Applies a showMessageBox result. Returns whether to launch; persists only Yes + checked
 * (No never persists, so declining can't silently turn the feature off for good).
 */
function applyConsentAnswer(userData, { response, checkboxChecked }) {
  const yes = response === 0;
  if (yes && checkboxChecked) setConsentRemembered(userData, true);
  return yes;
}

// ---- Recents --------------------------------------------------------------

function recentKey(item) {
  return item.kind === 'title' ? `title:${item.id}` : `file:${String(item.path).toLowerCase()}`;
}

function loadRecents(userData) {
  const list = readJson(path.join(userData, RECENTS_FILE));
  return Array.isArray(list)
    ? list.filter((r) => r && (r.kind === 'title' ? typeof r.id === 'string' : typeof r.path === 'string'))
    : [];
}

/** Most recent first, de-duplicated, capped. Returns the new list. */
function addRecent(userData, item) {
  const entry = item.kind === 'title'
    ? { kind: 'title', id: item.id, name: item.name }
    : { kind: 'file', path: item.path, name: item.name };
  const key = recentKey(entry);
  const next = [entry, ...loadRecents(userData).filter((r) => recentKey(r) !== key)].slice(0, MAX_RECENTS);
  try { writeJson(path.join(userData, RECENTS_FILE), next); } catch { /* convenience only */ }
  return next;
}

// ---- What was picked, and how it starts ----------------------------------

function fileKind(filePath) {
  const ext = win.extname(String(filePath || '')).toLowerCase();
  return LAUNCHABLE_EXTENSIONS.includes(ext) ? ext.slice(1) : null;
}

/** Display name for a file: the shortcut or executable name without its extension. */
function displayName(filePath) {
  return win.basename(filePath, win.extname(filePath));
}

/**
 * How a title starts. Flat titles always start on the desktop. A VR or both title goes through
 * PCVR while its session is on; while the session is still starting the caller waits (bounded)
 * for the headset and then decides again ('wait'); with no session it starts on the desktop —
 * for a VR-only title that is Steam's own behaviour, its VR entry with no headset streaming.
 */
function launchModeFor(pcvrConnected, foveatedStatus, kind = 'vr') {
  if (kind === 'flat') return 'flat';
  if (!pcvrConnected || !foveatedStatus) return 'flat';
  if (foveatedStatus.state === 'on') return 'vr';
  if (foveatedStatus.state === 'starting') return 'wait';
  return 'flat';
}

/** Library titles matching a search, best first: name prefix, then word prefix, then substring. */
function searchTitles(titles, query, limit = 50) {
  const q = String(query || '').trim().toLowerCase();
  if (!Array.isArray(titles)) return [];
  if (!q) return titles.slice(0, limit);
  const scored = [];
  for (const t of titles) {
    const name = String(t.name || '').toLowerCase();
    const at = name.indexOf(q);
    if (at < 0) continue;
    const score = at === 0 ? 0 : /[\s:\-_.]/.test(name[at - 1]) ? 1 : 2;
    scored.push([score, name, t]);
  }
  scored.sort((a, b) => a[0] - b[0] || a[1].localeCompare(b[1]));
  return scored.slice(0, limit).map((x) => x[2]);
}

/** The Steam app id a steam:// URL starts, or null (steam://rungameid/N, steam://run/N). */
function steamAppIdFromUrl(url) {
  const m = /^steam:\/\/(?:rungameid|run|launch)\/(\d+)/i.exec(String(url || ''));
  return m ? Number(m[1]) : null;
}

/** The URL= line of an Internet Shortcut (.url) file's [InternetShortcut] section, or null. */
function parseInternetShortcut(text) {
  let inSection = false;
  for (const raw of String(text).split(/\r?\n/)) {
    const line = raw.trim();
    if (/^\[.*\]$/.test(line)) { inSection = /^\[InternetShortcut\]$/i.test(line); continue; }
    if (inSection && /^URL=/i.test(line)) return line.slice(4).trim() || null;
  }
  return null;
}

/**
 * Whether a .url target may be opened. It goes to the scheme's registered handler (Steam, Epic,
 * a browser) in the user's session. file: is refused: ShellExecute on a file can run anything,
 * elevated if it asks, which is the one thing this launcher never does.
 */
function urlAllowed(url) {
  const m = /^([a-z][a-z0-9+.-]*):/i.exec(String(url || ''));
  return Boolean(m) && m[1].toLowerCase() !== 'file';
}

/** Environment for a bare launch: ours minus Electron's own variables, plus a Steam identity. */
function childEnvironment(baseEnv, steamAppId) {
  const env = {};
  for (const [k, v] of Object.entries(baseEnv || {})) {
    if (!/^ELECTRON_|^CHROME_/i.test(k)) env[k] = v;
  }
  if (steamAppId) {
    env.SteamAppId = String(steamAppId);
    env.SteamGameId = String(steamAppId);
  }
  return env;
}

// ---- Command line ----------------------------------------------------------

const TITLE_ID = /^(steam:\d+|custom:[0-9a-f]{6,32})$/i;

/**
 * The game a command line asks for, or null:
 *   `--launch-title <id>` / `--launch-title=<id>` → { titleId } (shortcuts to library titles);
 *   `--launch <path>`, `--launch=<path>`, or a bare path (what Windows passes when a game is
 *   dropped on the exe or its shortcut) → { path }.
 * Switches are skipped, and only an existing file with a launchable extension counts as a path,
 * so Electron's and Chromium's own arguments are never mistaken for a game. `skip` is how many
 * leading entries are the program itself (1 packaged, 2 for `electron .` in a checkout).
 * Relative paths resolve against `cwd` — a second instance's, when handed over. `pathApi` is the
 * platform's path module; tests pass path.win32.
 */
function gameRequestFromArgv(argv, {
  skip = 1, cwd = process.cwd(), exists = fs.existsSync, pathApi = path,
} = {}) {
  const args = Array.isArray(argv) ? argv.slice(skip) : [];
  const accept = (candidate) => {
    if (typeof candidate !== 'string' || candidate.length === 0) return null;
    const full = pathApi.isAbsolute(candidate)
      ? pathApi.normalize(candidate)
      : pathApi.resolve(cwd || '', candidate);
    return fileKind(full) && exists(full) ? { path: full } : null;
  };
  const acceptId = (id) => (typeof id === 'string' && TITLE_ID.test(id) ? { titleId: id } : null);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--launch-title') return acceptId(args[i + 1]);
    if (a.startsWith('--launch-title=')) return acceptId(a.slice('--launch-title='.length));
    if (a === '--launch') return accept(args[i + 1]);
    if (a.startsWith('--launch=')) return accept(a.slice('--launch='.length));
  }
  for (const a of args) {
    if (a.startsWith('-')) continue;
    const found = accept(a);
    if (found) return found;
  }
  return null;
}

/** The arguments a desktop shortcut passes to the Companion for a request. */
function shortcutArguments(request) {
  if (request && request.titleId && TITLE_ID.test(request.titleId)) return `--launch-title ${request.titleId}`;
  if (request && request.path) return `--launch "${request.path}"`;
  throw new Error('nothing to make a shortcut for');
}

/** A file name for a shortcut: the game's name without characters Windows forbids. */
function shortcutFileName(name) {
  return `${String(name || '').replace(/[<>:"/\\|?*\x00-\x1f]/g, '').replace(/[. ]+$/, '').trim() || 'Game'}.lnk`;
}

module.exports = {
  LAUNCH_EFFECTS,
  CONSENT_FILE,
  RECENTS_FILE,
  MAX_RECENTS,
  consentMessageOptions,
  consentRemembered,
  setConsentRemembered,
  applyConsentAnswer,
  recentKey,
  loadRecents,
  addRecent,
  fileKind,
  displayName,
  launchModeFor,
  searchTitles,
  steamAppIdFromUrl,
  parseInternetShortcut,
  urlAllowed,
  childEnvironment,
  gameRequestFromArgv,
  shortcutArguments,
  shortcutFileName,
};
