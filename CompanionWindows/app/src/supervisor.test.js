'use strict';
// Run with: npm test  (node --test, no framework)
//
// Covers the optional services.json a PCVR bundle may ship next to the broker. The file
// decides what gets spawned, so the loader must refuse anything that is not a bare .exe in
// the bridge directory — and a bundle with no file at all must behave exactly like one with
// an empty list.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Supervisor, loadExtraServices } = require('./supervisor');

function tempBridge(servicesJson) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lw-bridge-'));
  if (servicesJson !== undefined) {
    fs.writeFileSync(path.join(dir, 'services.json'),
      typeof servicesJson === 'string' ? servicesJson : JSON.stringify(servicesJson));
  }
  return dir;
}

test('no bridge directory, or no services.json, means no extra services', () => {
  assert.deepStrictEqual(loadExtraServices(null), []);
  assert.deepStrictEqual(loadExtraServices(tempBridge()), []);
});

test('malformed JSON is ignored and reported, not thrown', () => {
  const logs = [];
  assert.deepStrictEqual(loadExtraServices(tempBridge('{ nope'), (m) => logs.push(m)), []);
  assert.strictEqual(logs.length, 1);
});

test('a valid entry is loaded with defaults filled in', () => {
  const out = loadExtraServices(tempBridge({
    services: [{ name: 'extra', image: 'extra.exe', args: ['--watch'], restart: true }],
  }));
  assert.strictEqual(out.length, 1);
  assert.deepStrictEqual(out[0], {
    name: 'extra', title: 'extra', image: 'extra.exe', args: ['--watch'], env: {},
    restart: true, oneShot: false,
  });
});

test('entries that could spawn something else, or clash, are skipped', () => {
  const logs = [];
  const out = loadExtraServices(tempBridge({
    services: [
      { name: 'broker', image: 'x.exe' },                  // built-in name
      { name: 'a', image: '..\\evil.exe' },                  // path, not a bare name
      { name: 'b', image: 'C:\\Windows\\evil.exe' },
      { name: 'c', image: 'sub/evil.exe' },
      { name: 'd', image: 'notanexe.bat' },
      { name: 'Upper', image: 'ok.exe' },                   // bad name
      { name: 'e', image: 'ok.exe', args: [1] },            // non-string args
      { name: 'f', image: 'ok.exe', env: { A: 1 } },        // non-string env
      { name: 'g', image: 'ok.exe' },
      { name: 'g', image: 'dup.exe' },                      // duplicate
    ],
  }), (m) => logs.push(m));
  assert.deepStrictEqual(out.map((s) => s.name), ['g']);
  assert.strictEqual(logs.length, 9);
});

test('the supervisor knows only the broker without a descriptor file', () => {
  const bridge = tempBridge();
  const sup = new Supervisor({ appRoot: path.join(bridge, 'app'), backendExe: null, bridgeRoot: bridge });
  assert.deepStrictEqual(sup.names, ['broker']);
  assert.deepStrictEqual(sup.extraServiceNames, []);
  assert.deepStrictEqual(Object.keys(sup.status()), ['broker']);
});

test('declared services join after the broker, in file order, and resolve in the bridge', () => {
  const bridge = tempBridge({
    services: [
      { name: 'one', title: 'One', image: 'one.exe' },
      { name: 'two', image: 'two.exe', oneShot: true },
    ],
  });
  fs.writeFileSync(path.join(bridge, 'one.exe'), '');
  const sup = new Supervisor({ appRoot: path.join(bridge, 'app'), backendExe: null, bridgeRoot: bridge });
  assert.deepStrictEqual(sup.names, ['broker', 'one', 'two']);
  assert.deepStrictEqual(sup.extraServiceNames, ['one', 'two']);
  const status = sup.status();
  assert.strictEqual(status.one.title, 'One');
  assert.strictEqual(status.one.exe, path.join(bridge, 'one.exe'));
  assert.strictEqual(status.two.exe, null);        // declared but not shipped
  assert.strictEqual(status.two.oneShot, true);

  // Re-resolving after an install picks the file up (or drops it) without a restart.
  fs.unlinkSync(path.join(bridge, 'services.json'));
  sup.refreshPaths(null, bridge);
  assert.deepStrictEqual(sup.names, ['broker']);
});
