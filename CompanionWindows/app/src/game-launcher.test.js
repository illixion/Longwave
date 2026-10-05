'use strict';
// Run with: npm test  (node --test, no framework)
//
// The tray launcher's decisions: consent persistence, recents, the command-line game argument,
// library matching, .url handling, and which Steam app owns a browsed exe (both the Steam case
// and the plain non-Steam one).
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const gl = require('./game-launcher');
const steam = require('./steam-locate');

const tempDir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'lw-launch-'));

test('consent: only Yes with the checkbox persists, and deleting the file re-asks', () => {
  const dir = tempDir();
  assert.strictEqual(gl.consentRemembered(dir), false);
  assert.strictEqual(gl.applyConsentAnswer(dir, { response: 1, checkboxChecked: true }), false);
  assert.strictEqual(gl.consentRemembered(dir), false, 'No never persists');
  assert.strictEqual(gl.applyConsentAnswer(dir, { response: 0, checkboxChecked: false }), true);
  assert.strictEqual(gl.consentRemembered(dir), false, 'Yes without the checkbox asks again');
  assert.strictEqual(gl.applyConsentAnswer(dir, { response: 0, checkboxChecked: true }), true);
  assert.strictEqual(gl.consentRemembered(dir), true);
  fs.rmSync(path.join(dir, gl.CONSENT_FILE));
  assert.strictEqual(gl.consentRemembered(dir), false);
  gl.setConsentRemembered(dir, true);
  gl.setConsentRemembered(dir, false);
  assert.strictEqual(gl.consentRemembered(dir), false);
});

test('consent box: Yes/No, Yes default, No cancels, every effect listed, no audio claim', () => {
  const o = gl.consentMessageOptions();
  assert.deepStrictEqual(o.buttons, ['Yes', 'No']);
  assert.strictEqual(o.defaultId, 0);
  assert.strictEqual(o.cancelId, 1);
  assert.strictEqual(o.type, 'question');
  assert.strictEqual(o.checkboxLabel, "Don't ask again");
  for (const line of gl.LAUNCH_EFFECTS) assert.ok(o.detail.includes(line));
  assert.ok(!/audio/i.test(o.detail), 'the audio component ships with the v3 audio channel');
});

test('recents: newest first, de-duplicated (paths case-insensitively), capped', () => {
  const dir = tempDir();
  gl.addRecent(dir, { kind: 'file', path: 'C:\\Games\\A\\a.exe', name: 'a' });
  gl.addRecent(dir, { kind: 'title', id: 'steam:1', name: 'One' });
  const list = gl.addRecent(dir, { kind: 'file', path: 'c:\\games\\a\\A.EXE', name: 'a' });
  assert.deepStrictEqual(list.map((r) => r.kind), ['file', 'title']);
  for (let i = 0; i < 10; i++) gl.addRecent(dir, { kind: 'title', id: `steam:${100 + i}`, name: `${i}` });
  assert.strictEqual(gl.loadRecents(dir).length, gl.MAX_RECENTS);
  fs.writeFileSync(path.join(dir, gl.RECENTS_FILE), '{garbage');
  assert.deepStrictEqual(gl.loadRecents(dir), []);
});

test('launch mode: VR only while the PCVR host is connected and its session on or starting', () => {
  assert.strictEqual(gl.launchModeFor(false, { state: 'on' }), 'flat');
  assert.strictEqual(gl.launchModeFor(true, null), 'flat');
  assert.strictEqual(gl.launchModeFor(true, { state: 'off' }), 'flat');
  assert.strictEqual(gl.launchModeFor(true, { state: 'error' }), 'flat');
  assert.strictEqual(gl.launchModeFor(true, { state: 'on' }), 'vr');
  assert.strictEqual(gl.launchModeFor(true, { state: 'starting' }), 'vr');
});

test('library match: exact custom executable, or inside a Steam title install dir', () => {
  const titles = [
    { id: 'custom:1', source: 'custom', executable: 'D:\\Games\\Foo\\foo.exe' },
    { id: 'steam:546560', source: 'steam', installDir: 'C:\\Steam\\steamapps\\common\\Half-Life Alyx' },
  ];
  assert.strictEqual(gl.matchTitleForExecutable(titles, 'd:\\games\\foo\\FOO.exe').id, 'custom:1');
  assert.strictEqual(gl.matchTitleForExecutable(titles,
    'C:\\Steam\\steamapps\\common\\Half-Life Alyx\\game\\bin\\win64\\hlvr.exe').id, 'steam:546560');
  assert.strictEqual(gl.matchTitleForExecutable(titles,
    'C:\\Steam\\steamapps\\common\\Half-Life Alyx 2\\x.exe'), null, 'a sibling dir is not inside');
  assert.strictEqual(gl.matchTitleForExecutable(titles, 'D:\\Games\\Bar\\bar.exe'), null);
});

test('.url files: URL extraction, steam ids, and file: refused', () => {
  const text = '[{000214A0-0000-0000-C000-000000000046}]\r\nURL=nope\r\n[InternetShortcut]\r\nIDList=\r\nURL=steam://rungameid/1091500\r\nIconIndex=0\r\n';
  const url = gl.parseInternetShortcut(text);
  assert.strictEqual(url, 'steam://rungameid/1091500');
  assert.strictEqual(gl.steamAppIdFromUrl(url), 1091500);
  assert.strictEqual(gl.steamAppIdFromUrl('com.epicgames.launcher://apps/x?action=launch'), null);
  assert.strictEqual(gl.urlAllowed('com.epicgames.launcher://apps/x'), true);
  assert.strictEqual(gl.urlAllowed('file:///C:/Windows/System32/cmd.exe'), false);
  assert.strictEqual(gl.urlAllowed('not a url'), false);
  assert.strictEqual(gl.parseInternetShortcut('[Other]\nURL=x'), null);
});

test('child environment: drops Electron variables, adds the Steam identity only for Steam', () => {
  const base = { PATH: 'p', ELECTRON_RUN_AS_NODE: '1', CHROME_CRASHPAD_PIPE_NAME: 'x' };
  assert.deepStrictEqual(gl.childEnvironment(base, null), { PATH: 'p' });
  assert.deepStrictEqual(gl.childEnvironment(base, 1091500),
    { PATH: 'p', SteamAppId: '1091500', SteamGameId: '1091500' });
});

test('command line: --launch, --launch=, and a bare dropped path; switches never count', () => {
  const real = new Set(['D:\\Games\\Foo\\foo.exe', 'C:\\Users\\me\\Desktop\\Bar.lnk', 'C:\\work\\baz.url']);
  const exists = (p) => real.has(p);
  const pathApi = path.win32;
  const exe = 'C:\\Program Files\\Longwave Companion\\Longwave Companion.exe';
  assert.strictEqual(gl.gamePathFromArgv([exe, '--launch', 'D:\\Games\\Foo\\foo.exe'], { exists, pathApi }),
    'D:\\Games\\Foo\\foo.exe');
  assert.strictEqual(gl.gamePathFromArgv([exe, '--launch=C:\\Users\\me\\Desktop\\Bar.lnk'], { exists, pathApi }),
    'C:\\Users\\me\\Desktop\\Bar.lnk');
  assert.strictEqual(gl.gamePathFromArgv(
    [exe, '--allow-file-access-from-files', '--original-process-start-time=1', 'D:\\Games\\Foo\\foo.exe'], { exists, pathApi }),
  'D:\\Games\\Foo\\foo.exe');
  assert.strictEqual(gl.gamePathFromArgv([exe, 'baz.url'], { exists, pathApi, cwd: 'C:\\work' }), 'C:\\work\\baz.url');
  assert.strictEqual(gl.gamePathFromArgv([exe], { exists, pathApi }), null);
  assert.strictEqual(gl.gamePathFromArgv([exe, 'D:\\Games\\Foo\\readme.txt'], { exists: () => true, pathApi }), null);
  assert.strictEqual(gl.gamePathFromArgv([exe, 'D:\\Games\\Missing\\x.exe'], { exists, pathApi }), null);
  assert.strictEqual(gl.gamePathFromArgv([exe, '--launch', 'D:\\Games\\Missing\\x.exe'], { exists, pathApi }), null);
  // `electron .` in a checkout: the app directory is not a game.
  assert.strictEqual(gl.gamePathFromArgv(['electron.exe', '.', 'D:\\Games\\Foo\\foo.exe'], { skip: 2, exists, pathApi }),
    'D:\\Games\\Foo\\foo.exe');
});

// ---- Steam ownership of a browsed exe ----

function fakeSteam() {
  const files = {
    'C:\\Steam\\steam.exe': '',
    'C:\\Steam\\steamapps\\libraryfolders.vdf':
      '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"C:\\\\Steam"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"D:\\\\SteamLibrary"\n\t\t"apps"\n\t\t{\n\t\t\t"1091500"\t\t"1"\n\t\t}\n\t}\n}\n',
    'D:\\SteamLibrary\\steamapps\\appmanifest_1091500.acf':
      '"AppState"\n{\n\t"appid"\t\t"1091500"\n\t"name"\t\t"Cyberpunk 2077"\n\t"installdir"\t\t"Cyberpunk 2077"\n}\n',
    'C:\\Steam\\steamapps\\appmanifest_250820.acf':
      '"AppState"\n{\n\t"appid"\t\t"250820"\n\t"name"\t\t"SteamVR"\n\t"installdir"\t\t"SteamVR"\n}\n',
  };
  const dirs = {
    'C:\\Steam\\steamapps': ['appmanifest_250820.acf', 'libraryfolders.vdf'],
    'D:\\SteamLibrary\\steamapps': ['appmanifest_1091500.acf', 'common'],
  };
  return {
    existsSync: (p) => p in files || p in dirs,
    readFileSync: (p) => { if (!(p in files)) throw new Error('ENOENT'); return files[p]; },
    readdirSync: (p) => { if (!(p in dirs)) throw new Error('ENOENT'); return dirs[p]; },
  };
}

test('steam: libraries include the root and every libraryfolders.vdf path', () => {
  assert.deepStrictEqual(steam.steamLibraries('C:\\Steam', fakeSteam()), ['C:\\Steam', 'D:\\SteamLibrary']);
  assert.deepStrictEqual(steam.parseLibraryFolders('"LibraryFolders"\n{\n"TimeNextStatsReport" "1"\n"1" "E:\\\\Old"\n}'),
    ['E:\\Old']);
});

test('steam: a browsed exe in a secondary library gets its owning app', () => {
  const app = steam.findOwningSteamApp(
    'D:\\SteamLibrary\\steamapps\\common\\Cyberpunk 2077\\bin\\x64\\Cyberpunk2077.exe', 'C:\\Steam', fakeSteam());
  assert.deepStrictEqual(app, {
    appId: 1091500, name: 'Cyberpunk 2077',
    installDir: 'D:\\SteamLibrary\\steamapps\\common\\Cyberpunk 2077',
  });
  // Case of the folder does not matter on Windows.
  assert.strictEqual(steam.findOwningSteamApp(
    'd:\\steamlibrary\\STEAMAPPS\\common\\cyberpunk 2077\\x.exe', 'C:\\Steam', fakeSteam()).appId, 1091500);
});

test('steam: non-Steam exes, unknown folders and tools get no identity', () => {
  const fsApi = fakeSteam();
  assert.strictEqual(steam.findOwningSteamApp('D:\\Games\\Foo\\foo.exe', 'C:\\Steam', fsApi), null);
  assert.strictEqual(steam.findOwningSteamApp(
    'D:\\SteamLibrary\\steamapps\\common\\Unmanifested\\x.exe', 'C:\\Steam', fsApi), null);
  assert.strictEqual(steam.findOwningSteamApp(
    'C:\\Steam\\steamapps\\common\\SteamVR\\bin\\vrstartup.exe', 'C:\\Steam', fsApi), null);
  assert.strictEqual(steam.findOwningSteamApp('D:\\x.exe', null, fsApi), null);
});
