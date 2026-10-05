'use strict';
// Run with: npm test  (node --test, no framework)
//
// The launcher's decisions: consent persistence, recents, the command-line game argument,
// shortcuts, picker search, .url handling, VR/desktop routing — and the Games tab's view maths
// (renderer/library-view.js). Which Steam app owns a browsed exe is the backend library's
// MatchPath now; its tests are in CompanionWindows/backend-tests.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const gl = require('./game-launcher');
const lv = require('./renderer/library-view');

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

test('launch mode: flat stays flat; VR goes to PCVR when on, waits while starting', () => {
  assert.strictEqual(gl.launchModeFor(true, { state: 'on' }, 'flat'), 'flat');
  assert.strictEqual(gl.launchModeFor(false, { state: 'on' }, 'vr'), 'flat');
  assert.strictEqual(gl.launchModeFor(true, null, 'vr'), 'flat');
  assert.strictEqual(gl.launchModeFor(true, { state: 'off' }, 'both'), 'flat');
  assert.strictEqual(gl.launchModeFor(true, { state: 'error' }, 'vr'), 'flat');
  assert.strictEqual(gl.launchModeFor(true, { state: 'on' }, 'vr'), 'vr');
  assert.strictEqual(gl.launchModeFor(true, { state: 'on' }, 'both'), 'vr');
  assert.strictEqual(gl.launchModeFor(true, { state: 'starting' }, 'vr'), 'wait');
});

test('picker search: prefix, then word start, then substring; capped', () => {
  const titles = ['Half-Life: Alyx', 'Alyx', 'The Alyx Thing', 'Malyxia', 'Portal'].map((name) => ({ name }));
  assert.deepStrictEqual(gl.searchTitles(titles, 'alyx').map((t) => t.name),
    ['Alyx', 'Half-Life: Alyx', 'The Alyx Thing', 'Malyxia']);
  assert.strictEqual(gl.searchTitles(titles, 'zzz').length, 0);
  assert.strictEqual(gl.searchTitles(titles, '', 2).length, 2);
  const many = Array.from({ length: 5000 }, (_, i) => ({ name: `Game ${i}` }));
  assert.strictEqual(gl.searchTitles(many, 'game', 50).length, 50);
});

test('shortcuts: library titles by id, other files by path, safe file names', () => {
  assert.strictEqual(gl.shortcutArguments({ titleId: 'steam:546560' }), '--launch-title steam:546560');
  assert.strictEqual(gl.shortcutArguments({ path: 'D:\\Games\\Foo\\foo.exe' }), '--launch "D:\\Games\\Foo\\foo.exe"');
  assert.throws(() => gl.shortcutArguments({ titleId: 'steam:1 & calc' }));
  assert.strictEqual(gl.shortcutFileName('Half-Life: Alyx'), 'Half-Life Alyx.lnk');
  assert.strictEqual(gl.shortcutFileName('a/b\\c?.'), 'abc.lnk');
  assert.strictEqual(gl.shortcutFileName(''), 'Game.lnk');
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

test('command line: --launch, --launch=, a bare dropped path, --launch-title; switches never count', () => {
  const real = new Set(['D:\\Games\\Foo\\foo.exe', 'C:\\Users\\me\\Desktop\\Bar.lnk', 'C:\\work\\baz.url']);
  const exists = (p) => real.has(p);
  const pathApi = path.win32;
  const exe = 'C:\\Program Files\\Longwave Companion\\Longwave Companion.exe';
  const req = (argv, extra = {}) => gl.gameRequestFromArgv(argv, { exists, pathApi, ...extra });
  assert.deepStrictEqual(req([exe, '--launch', 'D:\\Games\\Foo\\foo.exe']), { path: 'D:\\Games\\Foo\\foo.exe' });
  assert.deepStrictEqual(req([exe, '--launch=C:\\Users\\me\\Desktop\\Bar.lnk']), { path: 'C:\\Users\\me\\Desktop\\Bar.lnk' });
  assert.deepStrictEqual(req([exe, '--allow-file-access-from-files', '--original-process-start-time=1', 'D:\\Games\\Foo\\foo.exe']),
    { path: 'D:\\Games\\Foo\\foo.exe' });
  assert.deepStrictEqual(req([exe, 'baz.url'], { cwd: 'C:\\work' }), { path: 'C:\\work\\baz.url' });
  assert.deepStrictEqual(req([exe, '--launch-title', 'steam:546560']), { titleId: 'steam:546560' });
  assert.deepStrictEqual(req([exe, '--launch-title=custom:f049dff7a5d7']), { titleId: 'custom:f049dff7a5d7' });
  assert.strictEqual(req([exe, '--launch-title', '..\\..\\evil']), null);
  assert.strictEqual(req([exe]), null);
  assert.strictEqual(gl.gameRequestFromArgv([exe, 'D:\\Games\\Foo\\readme.txt'], { exists: () => true, pathApi }), null);
  assert.strictEqual(req([exe, 'D:\\Games\\Missing\\x.exe']), null);
  assert.strictEqual(req([exe, '--launch', 'D:\\Games\\Missing\\x.exe']), null);
  // `electron .` in a checkout: the app directory is not a game.
  assert.deepStrictEqual(req(['electron.exe', '.', 'D:\\Games\\Foo\\foo.exe'], { skip: 2 }), { path: 'D:\\Games\\Foo\\foo.exe' });
});

// ---- Games tab view maths (renderer/library-view.js) ----

const sample = [
  { id: 'a', name: 'Beat Saber', kind: 'vr', lastPlayed: '2026-10-01T10:00:00Z', sizeBytes: 1e9 },
  { id: 'b', name: 'alyx', kind: 'vr', sizeBytes: 7e10 },
  { id: 'c', name: 'Cyberpunk 2077', kind: 'flat', lastPlayed: '2026-10-04T10:00:00Z', sizeBytes: 6e10 },
  { id: 'd', name: 'Portal 2', kind: 'both' },
];

test('library view: kind filters (both belongs to each), search, sorts', () => {
  const ids = (opts) => lv.visibleTitles(sample, opts).map((t) => t.id);
  assert.deepStrictEqual(ids({}), ['b', 'a', 'c', 'd']);
  assert.deepStrictEqual(ids({ kind: 'vr' }), ['b', 'a', 'd']);
  assert.deepStrictEqual(ids({ kind: 'flat' }), ['c', 'd']);
  assert.deepStrictEqual(ids({ query: 'POR' }), ['d']);
  assert.deepStrictEqual(ids({ sort: 'played' }), ['c', 'a', 'b', 'd']);
  assert.deepStrictEqual(ids({ sort: 'size' }), ['b', 'c', 'a', 'd']);
  assert.deepStrictEqual(ids({ sort: 'kind' }), ['b', 'a', 'd', 'c']);
  assert.strictEqual(sample[0].id, 'a', 'input is not reordered');
});

test('library view: grid by default only when the library is mostly VR', () => {
  assert.strictEqual(lv.defaultView(sample), 'grid');
  assert.strictEqual(lv.defaultView([...sample, ...Array(10).fill({ kind: 'flat' })]), 'list');
  assert.strictEqual(lv.defaultView([]), 'grid');
});

test('library view: windowing renders only what is on screen, for any library size', () => {
  const w = lv.windowFor({ count: 100000, rowHeight: 40, scrollTop: 400000, viewportHeight: 600, overscan: 8 });
  assert.strictEqual(w.totalHeight, 4000000);
  assert.strictEqual(w.start, 10000 - 8);
  assert.ok(w.end - w.start <= 15 + 16 + 1, `rendered ${w.end - w.start} rows`);
  assert.strictEqual(w.offsetTop, w.start * 40);
  const g = lv.windowFor({ count: 10, columns: 4, rowHeight: 200, scrollTop: 0, viewportHeight: 300, overscan: 0 });
  assert.deepStrictEqual([g.start, g.end, g.totalHeight], [0, 8, 600]);
  const end = lv.windowFor({ count: 10, columns: 4, rowHeight: 200, scrollTop: 5000, viewportHeight: 300, overscan: 1 });
  assert.ok(end.start <= end.end && end.end === 10);
  assert.strictEqual(lv.gridColumns(600, 136, 12), 4);
  assert.strictEqual(lv.gridColumns(50, 136, 12), 1);
});

test('library view: size and last-played formatting', () => {
  assert.strictEqual(lv.formatSize(0), '');
  assert.strictEqual(lv.formatSize(1234567890), '1.2 GB');
  assert.strictEqual(lv.formatSize(70e9), '70.0 GB');
  const now = Date.parse('2026-10-05T15:00:00');
  assert.strictEqual(lv.formatPlayed(new Date(now - 3600e3).toISOString(), now), 'Today');
  assert.strictEqual(lv.formatPlayed(new Date(now - 26 * 3600e3).toISOString(), now), 'Yesterday');
  assert.match(lv.formatPlayed(new Date(now - 5 * 86400e3).toISOString(), now), /days ago/);
  assert.strictEqual(lv.formatPlayed(null, now), '');
});
