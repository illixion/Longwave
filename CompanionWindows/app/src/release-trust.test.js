'use strict';
// Run with: npm test  (node --test, no framework)
//
// These cover the manifest parser and the key material rather than the network paths,
// because the parser is where a shortcut becomes a security hole: everything downstream —
// the app updater and the PCVR bundle installer — decides what to execute based on what
// this file says a signed manifest contained.
const test = require('node:test');
const assert = require('node:assert');
const trust = require('./release-trust');

const H1 = 'a'.repeat(64);
const H2 = 'b'.repeat(64);

test('parses the two-space coreutils form', () => {
  const m = trust.parseManifest(`${H1}  Longwave-0.1.0-abc12345.ipa\n${H2}  SHA256SUMS.notme\n`);
  assert.strictEqual(m.size, 2);
  assert.strictEqual(m.get('Longwave-0.1.0-abc12345.ipa'), H1);
});

test('parses binary mode (HASH *name) and tolerates CRLF', () => {
  const m = trust.parseManifest(`${H1} *LongwaveCompanion-0.1.0-x64-Setup.exe\r\n`);
  assert.strictEqual(m.get('LongwaveCompanion-0.1.0-x64-Setup.exe'), H1);
});

test('keeps spaces inside filenames intact', () => {
  const m = trust.parseManifest(`${H1}  Longwave Companion Setup.exe\n`);
  assert.strictEqual(m.get('Longwave Companion Setup.exe'), H1);
});

test('a duplicate filename is fatal, not last-wins', () => {
  // The attack this blocks: a manifest a human skims as listing one hash for an asset, while
  // the parser silently honours a second line further down.
  assert.throws(
    () => trust.parseManifest(`${H1}  dup.exe\n${H2}  dup.exe\n`),
    /more than once/,
  );
});

test('a malformed line is fatal, not skipped', () => {
  // A truncated download must not read as "that asset simply isn't covered".
  assert.throws(() => trust.parseManifest(`${H1}  ok.exe\nnot-a-checksum-line\n`), /line 2/);
});

test('a short or non-hex hash is rejected', () => {
  assert.throws(() => trust.parseManifest('deadbeef  short.exe\n'), /not a checksum line/);
  assert.throws(() => trust.parseManifest(`${'g'.repeat(64)}  nonhex.exe\n`), /not a checksum line/);
});

test('an empty manifest is rejected', () => {
  assert.throws(() => trust.parseManifest('\n  \n'), /empty/);
});

// ---------------------------------------------------------------- SSHSIG verification
//
// Signed with the real `ssh-keygen -Y sign`, not with a hand-rolled fixture, so these exercise
// the actual wire format rather than this file's idea of it. The pinned signer list is
// swapped for a temporary one holding throwaway keys — which also means the recovery path (a
// second trusted key signing instead of the first) is tested for real, and not just on the day
// the YubiKey is actually lost.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const SIGNERS_FILE = path.join(__dirname, 'release-signers');
let sandbox = null;

function sshKeygen(dir, name) {
  execFileSync('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-C', name,
                              '-f', path.join(dir, name)]);
  return {
    private: path.join(dir, name),
    public: fs.readFileSync(path.join(dir, `${name}.pub`), 'utf8').trim(),
  };
}

// `ssh-keygen -Y sign` writes <file>.sig — and if that file already exists it leaves it
// ALONE and still exits 0. Signing twice over one path therefore hands back the FIRST
// signature with no error anywhere, which is how this helper originally "proved" that a
// backup-key signature verified as the primary key. Unlink first, then check one was written.
let signCounter = 0;
function sign(keyPath, dir, data, namespace = 'file') {
  const file = path.join(dir, `payload-${signCounter++}`);
  fs.writeFileSync(file, data);
  fs.rmSync(`${file}.sig`, { force: true });
  execFileSync('ssh-keygen', ['-Y', 'sign', '-n', namespace, '-f', keyPath, file],
               { stdio: 'ignore' });
  if (!fs.existsSync(`${file}.sig`)) throw new Error('ssh-keygen wrote no signature');
  return fs.readFileSync(`${file}.sig`, 'utf8');
}

test.before(() => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'longwave-trust-'));
  const primary = sshKeygen(dir, 'primary');
  const backup = sshKeygen(dir, 'backup');
  const stranger = sshKeygen(dir, 'stranger');
  // Stand in for the committed list for the duration of these tests, restored in test.after.
  const saved = fs.readFileSync(SIGNERS_FILE, 'utf8');
  fs.writeFileSync(SIGNERS_FILE,
    `releases@longwave.pro ${primary.public}\nreleases@longwave.pro ${backup.public}\n`);
  sandbox = { dir, primary, backup, stranger, saved };
});

test.after(() => {
  if (!sandbox) return;
  fs.writeFileSync(SIGNERS_FILE, sandbox.saved);
  fs.rmSync(sandbox.dir, { recursive: true, force: true });
});

test('the committed signer list parses and pins exactly two ed25519 keys', () => {
  // sandbox.saved is the real file's content, captured in test.before before it was swapped
  // out — reading SIGNERS_FILE here would only re-check the throwaway list.
  const shipped = sandbox.saved;
  const lines = shipped.split(/\r?\n/).filter((l) => l.trim() && !l.trim().startsWith('#'));
  assert.strictEqual(lines.length, 2, 'the everyday key and one offline backup');
  assert.ok(lines.every((l) => l.includes('ssh-ed25519')));
});

test('a real signature from the primary key verifies', () => {
  const data = Buffer.from('hash  asset.exe\n');
  const result = trust.verifySshSignature(data, sign(sandbox.primary.private, sandbox.dir, data));
  assert.match(result.signer, /primary/);
});

test('the offline backup key verifies too — the key-loss recovery path', () => {
  // The point of pinning two: if the YubiKey is gone, releases signed by the backup are still
  // accepted by copies of the app that shipped before anyone knew it was needed.
  const data = Buffer.from('hash  asset.exe\n');
  const result = trust.verifySshSignature(data, sign(sandbox.backup.private, sandbox.dir, data));
  assert.match(result.signer, /backup/);
});

test('a key that is not pinned is rejected however valid its signature', () => {
  const data = Buffer.from('payload');
  assert.throws(() => trust.verifySshSignature(data, sign(sandbox.stranger.private, sandbox.dir, data)),
                /not in the pinned release signer list/);
});

test('tampering with the signed data is caught', () => {
  const sig = sign(sandbox.primary.private, sandbox.dir, Buffer.from('original'));
  assert.throws(() => trust.verifySshSignature(Buffer.from('modified'), sig),
                /does not verify/);
});

test('a signature made for another namespace is rejected', () => {
  // A trusted key signing something else — a git commit, a file for another tool — must not
  // be replayable as a release manifest.
  const data = Buffer.from('payload');
  const sig = sign(sandbox.primary.private, sandbox.dir, data, 'git');
  assert.throws(() => trust.verifySshSignature(data, sig), /namespace "git"/);
});

test('garbage in place of a signature is rejected', () => {
  assert.throws(() => trust.verifySshSignature(Buffer.from('x'), 'not a signature'),
                /not an SSH signature/);
});

test('a truncated signature blob is rejected, not read past', () => {
  const sig = sign(sandbox.primary.private, sandbox.dir, Buffer.from('payload'));
  const body = sig.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const chopped = Buffer.from(body, 'base64').subarray(0, 40).toString('base64');
  assert.throws(() => trust.verifySshSignature(
    Buffer.from('payload'),
    `-----BEGIN SSH SIGNATURE-----\n${chopped}\n-----END SSH SIGNATURE-----\n`));
});

test('the legacy OpenPGP key is still a usable public key', async () => {
  // The pre-SSHSIG PCVR bundles verify against this one; catches it being truncated or
  // replaced with a private key by accident.
  const openpgp = require('openpgp');
  const key = await openpgp.readKey({ armoredKey: trust.LEGACY_GPG_KEY });
  assert.ok(!key.isPrivate(), 'the committed key must be the PUBLIC half');
});

test('verifyAgainstManifest refuses an asset the manifest does not cover', async () => {
  const manifest = { tag: '0.1.0-abc12345', entries: trust.parseManifest(`${H1}  covered.exe\n`) };
  await assert.rejects(
    () => trust.verifyAgainstManifest(manifest, 'uncovered.exe', __filename),
    /not listed in the signed manifest/,
  );
});

test('verifyAgainstManifest catches a hash mismatch', async () => {
  const manifest = { tag: 't', entries: trust.parseManifest(`${H1}  self.js\n`) };
  await assert.rejects(
    () => trust.verifyAgainstManifest(manifest, 'self.js', __filename),
    /does not match the signed manifest/,
  );
});

test('verifyAgainstManifest accepts the real hash of a real file', async () => {
  const actual = await trust.sha256File(__filename);
  const manifest = { tag: 't', entries: trust.parseManifest(`${actual}  self.js\n`) };
  assert.strictEqual(await trust.verifyAgainstManifest(manifest, 'self.js', __filename), actual);
});
