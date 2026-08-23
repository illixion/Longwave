'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

/**
 * The trust anchor shared by everything this app downloads: the app's own updates
 * (updater.js) and the closed-source PCVR bundle (pcvr-installer.js).
 *
 * WHY A SIGNED MANIFEST, AND WHY AT ALL
 *
 * The installers are not Authenticode-signed — there is no code-signing certificate, by
 * decision, so SmartScreen warns once and that is that. Tolerable for something a human
 * deliberately downloads from a release page and can check against the build-provenance
 * attestation. NOT tolerable for an updater, which fetches an .exe and runs it with no human
 * looking at the URL: unsigned auto-update is a remote-code-execution channel whose only
 * guarantee is "GitHub served it over TLS". That is also exactly why electron-updater is not
 * used here — on Windows it verifies a downloaded installer's publisher only when a real
 * certificate exists to derive `publisherName` from. With none, it downloads and runs
 * whatever the feed offers, silently.
 *
 * So authenticity comes from a key CI cannot hold. CI builds and publishes the release;
 * afterwards a human runs scripts/bless-release.sh, which hashes every asset attached to that
 * release into one `SHA256SUMS` and signs it with `ssh-keygen -Y sign` (SSHSIG). One signature
 * covers the whole release: both Windows installers, the visionOS IPAs, the macOS zips, and
 * the PCVR bundle. The private half lives on a YubiKey and has never touched a disk, let alone
 * a CI secret, so a stolen GitHub token or a compromised workflow can publish assets to a
 * release but cannot make this app accept them.
 *
 * SSHSIG rather than OpenPGP, and verified here by hand rather than with a library, for one
 * reason: the keys already exist. This is the same signing scheme, the same namespace and the
 * same two pinned signers as the ssh-keys-updater in illixion.github.io — including an offline
 * backup key — so there is one pair of keys to protect and one recovery drill to remember. The
 * verification is ~60 lines of SSH wire-format parsing plus one ed25519 check from node's own
 * crypto, which is less machinery than an OpenPGP implementation, not more.
 *
 * The signer list is committed next to this file precisely so anyone — not just this app — can
 * verify a release independently: see scripts/verify-release.sh.
 */
// Every key allowed to sign a release, in ssh-keygen allowed_signers format. TWO of them: the
// everyday YubiKey and an offline backup that exists so that losing the YubiKey is a recovery
// drill rather than the end of the update channel. See that file's own header.
const SIGNERS_FILE = path.join(__dirname, 'release-signers');
// The OpenPGP key that signed PCVR bundles before this mechanism existed. Kept only so
// already-published bundles still verify — nothing new is signed with it.
const LEGACY_GPG_KEY = fs.readFileSync(path.join(__dirname, 'release-signing-key.asc'), 'utf8');

const MANIFEST_NAME = 'SHA256SUMS';
const SIGNATURE_NAME = 'SHA256SUMS.sig';
// `ssh-keygen -Y sign -n file` — the same namespace the ssh-keys-updater manifests use, so one
// habit and one command cover both. A signature made for another namespace does not verify
// here even with a trusted key, which is what stops a signature over some unrelated file from
// being replayed as a release manifest.
const SSHSIG_NAMESPACE = 'file';

/**
 * Parses `sha256sum`/`shasum -a 256` output into name -> hash.
 *
 * Deliberately strict, because this is the one place where a parsing shortcut becomes a
 * security hole. Two rules earn their keep:
 *
 *   - A duplicate filename is a hard error, never last-wins or first-wins. A manifest listing
 *     one asset twice with different hashes has no single meaning, and whichever rule this
 *     picked would be a way to smuggle the other value past a human who checked by eye.
 *   - A line that does not parse is a hard error, not a skipped line. Silently ignoring
 *     malformed input turns "the manifest was truncated" into "that asset simply isn't
 *     covered", which then reads as success at every later step.
 *
 * Accepts both coreutils modes (`HASH  name` and binary-mode `HASH *name`) and tolerates
 * spaces inside filenames, which is why the hash is anchored and the remainder taken whole
 * rather than split on whitespace.
 */
function parseManifest(text) {
  const map = new Map();
  const lines = String(text).split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim()) continue;
    const m = /^([0-9a-f]{64})[ \t]+\*?(.+)$/.exec(line.trim());
    if (!m) throw new Error(`SHA256SUMS line ${i + 1} is not a checksum line: "${line.slice(0, 80)}"`);
    const name = m[2].trim();
    if (map.has(name)) throw new Error(`SHA256SUMS lists "${name}" more than once`);
    map.set(name, m[1]);
  }
  if (map.size === 0) throw new Error('SHA256SUMS is empty');
  return map;
}

// ---------------------------------------------------------------- SSHSIG verification
//
// The format is specified in OpenSSH's PROTOCOL.sshsig. Two structures matter:
//
//   the signature file       MAGIC "SSHSIG" | u32 version | str publickey | str namespace
//                            | str reserved | str hash_algorithm | str signature
//   the bytes actually signed
//                            MAGIC "SSHSIG" | str namespace | str reserved
//                            | str hash_algorithm | str H(message)
//
// where `str` is a uint32 big-endian length followed by that many bytes, and MAGIC is six raw
// bytes with no length prefix in both. The message is hashed first and only the hash is signed,
// which is why a 200 MB installer costs nothing to verify beyond reading it once.

const SSHSIG_MAGIC = Buffer.from('SSHSIG');
// ed25519 SubjectPublicKeyInfo prefix: SEQUENCE { SEQUENCE { OID 1.3.101.112 }, BIT STRING }.
// Fixed, because the key is always exactly 32 bytes — so wrapping a raw SSH key for node's
// crypto is a concatenation rather than a DER encoder.
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

/** Reads one SSH wire string, returning it and the offset just past it. */
function readSshString(buf, offset) {
  if (offset + 4 > buf.length) throw new Error('truncated SSH signature (length prefix)');
  const len = buf.readUInt32BE(offset);
  const start = offset + 4;
  if (len > buf.length - start) throw new Error('truncated SSH signature (body)');
  return { value: buf.subarray(start, start + len), next: start + len };
}

function writeSshString(bytes) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(bytes.length, 0);
  return Buffer.concat([len, bytes]);
}

/** Pulls the base64 payload out of an armored `-----BEGIN SSH SIGNATURE-----` block. */
function decodeSshSigArmor(armored) {
  const m = /-----BEGIN SSH SIGNATURE-----([\s\S]*?)-----END SSH SIGNATURE-----/.exec(String(armored));
  if (!m) throw new Error('not an SSH signature (no BEGIN/END SSH SIGNATURE block)');
  return Buffer.from(m[1].replace(/\s+/g, ''), 'base64');
}

/**
 * The pinned signer list. Parsed loosely on purpose — it is read as allowed_signers
 * (`principal keytype base64 comment`), but authorized_keys lines (`keytype base64 comment`)
 * are accepted too, by looking for the key type rather than counting columns. One file that
 * cannot be broken by which of the two formats someone pastes into it.
 */
function loadSigners() {
  const signers = [];
  for (const raw of fs.readFileSync(SIGNERS_FILE, 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const parts = line.split(/\s+/);
    const i = parts.findIndex((p) => p === 'ssh-ed25519');
    if (i === -1 || !parts[i + 1]) continue;   // another key type, or a malformed line
    signers.push({
      blob: Buffer.from(parts[i + 1], 'base64'),
      comment: parts.slice(i + 2).join(' ') || '(no comment)',
    });
  }
  if (!signers.length) throw new Error(`no usable signers in ${SIGNERS_FILE}`);
  return signers;
}

/**
 * Verifies a detached SSHSIG over `data` and returns the signer that made it.
 *
 * Throws on anything less than a full match: an untrusted key, the wrong namespace, an
 * unsupported algorithm, a malformed blob, or a bad signature. There is no boolean return and
 * no "unknown" state, so a caller cannot accidentally treat a failure as a pass.
 */
function verifySshSignature(data, armoredSignature, { namespace = SSHSIG_NAMESPACE } = {}) {
  const blob = decodeSshSigArmor(armoredSignature);
  if (!blob.subarray(0, SSHSIG_MAGIC.length).equals(SSHSIG_MAGIC)) {
    throw new Error('not an SSHSIG blob (bad magic)');
  }
  let off = SSHSIG_MAGIC.length;
  const version = blob.readUInt32BE(off); off += 4;
  if (version !== 1) throw new Error(`unsupported SSHSIG version ${version}`);

  const pk = readSshString(blob, off); off = pk.next;
  const ns = readSshString(blob, off); off = ns.next;
  const reserved = readSshString(blob, off); off = reserved.next;
  const hashAlg = readSshString(blob, off); off = hashAlg.next;
  const sigBlob = readSshString(blob, off);

  if (ns.value.toString('utf8') !== namespace) {
    // A valid signature over a different namespace is still a valid signature — just not one
    // authorising this. Rejecting it is what stops, say, a signed git commit or a signed file
    // from elsewhere being replayed here as a release manifest.
    throw new Error(`signature is for namespace "${ns.value.toString('utf8')}", expected "${namespace}"`);
  }

  const hashName = hashAlg.value.toString('utf8');
  if (hashName !== 'sha512' && hashName !== 'sha256') {
    throw new Error(`unsupported SSHSIG hash algorithm "${hashName}"`);
  }

  const signer = loadSigners().find((s) => s.blob.equals(pk.value));
  if (!signer) {
    throw new Error('signed by a key that is not in the pinned release signer list');
  }

  // Unpack the inner signature: str algorithm, str raw signature.
  const sigAlg = readSshString(sigBlob.value, 0);
  const sigRaw = readSshString(sigBlob.value, sigAlg.next);
  if (sigAlg.value.toString('utf8') !== 'ssh-ed25519') {
    throw new Error(`unsupported signature algorithm "${sigAlg.value.toString('utf8')}"`);
  }

  // The public key blob is itself `str "ssh-ed25519" | str <32 bytes>`.
  const pkAlg = readSshString(pk.value, 0);
  const pkRaw = readSshString(pk.value, pkAlg.next);
  if (pkAlg.value.toString('utf8') !== 'ssh-ed25519' || pkRaw.value.length !== 32) {
    throw new Error('pinned signer is not a usable ed25519 key');
  }
  const publicKey = crypto.createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, pkRaw.value]),
    format: 'der',
    type: 'spki',
  });

  const messageHash = crypto.createHash(hashName)
    .update(Buffer.isBuffer(data) ? data : Buffer.from(data, 'utf8'))
    .digest();
  const signedData = Buffer.concat([
    SSHSIG_MAGIC,
    writeSshString(ns.value),
    writeSshString(reserved.value),
    writeSshString(hashAlg.value),
    writeSshString(messageHash),
  ]);

  // ed25519 in node takes no digest algorithm — the scheme fixes it internally, hence null.
  if (!crypto.verify(null, signedData, publicKey, sigRaw.value)) {
    throw new Error('signature does not verify');
  }
  return { signer: signer.comment };
}

/**
 * Verifies the OpenPGP signature that PCVR bundles were signed with before SSHSIG. Legacy:
 * reached only by pcvr-installer.js for a bundle whose release has no signed manifest. Nothing
 * new is signed this way, and this can go once no such release matters.
 */
async function verifyGpgSignature(data, armoredSignature) {
  // Required lazily: openpgp is ~1 MB of JS and most launches never download anything.
  const openpgp = require('openpgp');
  const publicKey = await openpgp.readKey({ armoredKey: LEGACY_GPG_KEY });
  const message = await openpgp.createMessage({
    binary: Buffer.isBuffer(data) ? data : Buffer.from(data, 'utf8'),
  });
  const signature = await openpgp.readSignature({ armoredSignature });
  const { signatures } = await openpgp.verify({ message, signature, verificationKeys: publicKey });
  if (!signatures.length) throw new Error('no signature found in the .asc');
  // `signatures[0].verified` is a promise that REJECTS on a bad signature rather than
  // resolving false — awaiting it IS the check, and forgetting to await would pass
  // everything. On its own line so that is impossible to miss when reading.
  await signatures[0].verified;
}

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

/**
 * Fetches and verifies the signed manifest for one release tag.
 *
 * Returns null — rather than throwing — when the release has no manifest at all, so callers
 * can tell "this release was never blessed" (a real state for anything published before this
 * mechanism existed, and for a release whose blessing is still pending) from "the manifest is
 * present and does not check out", which is always fatal.
 */
async function fetchManifest(repo, tag) {
  const { net } = require('electron');
  const res = await net.fetch(
    `https://api.github.com/repos/${repo}/releases/tags/${encodeURIComponent(tag)}`,
    { headers: { 'User-Agent': 'Longwave-Companion', Accept: 'application/vnd.github+json' } },
  );
  if (!res.ok) throw new Error(`could not read release ${tag}: HTTP ${res.status}`);
  const release = await res.json();
  const assets = Array.isArray(release.assets) ? release.assets : [];
  const manifestAsset = assets.find((a) => a.name === MANIFEST_NAME);
  const signatureAsset = assets.find((a) => a.name === SIGNATURE_NAME);
  if (!manifestAsset || !signatureAsset) return null;

  const [manifestRes, signatureRes] = await Promise.all([
    net.fetch(manifestAsset.browser_download_url),
    net.fetch(signatureAsset.browser_download_url),
  ]);
  if (!manifestRes.ok) throw new Error(`could not fetch ${MANIFEST_NAME}: HTTP ${manifestRes.status}`);
  if (!signatureRes.ok) throw new Error(`could not fetch ${SIGNATURE_NAME}: HTTP ${signatureRes.status}`);
  const manifestText = await manifestRes.text();

  let signer;
  try {
    ({ signer } = verifySshSignature(manifestText, await signatureRes.text()));
  } catch (e) {
    throw new Error(
      `the release manifest's signature does not check out — refusing to trust any asset on `
      + `${tag}: ${e.message}`);
  }
  return { tag, entries: parseManifest(manifestText), assets, signer };
}

/**
 * Checks a downloaded file against a verified manifest. An asset the manifest does not cover
 * is a failure, not a pass: the signature says exactly which files the release vouches for,
 * and something else turning up under a covered release is precisely the case worth catching.
 */
async function verifyAgainstManifest(manifest, assetName, filePath) {
  const expected = manifest.entries.get(assetName);
  if (!expected) {
    throw new Error(`${assetName} is not listed in the signed manifest for ${manifest.tag}`);
  }
  const actual = await sha256File(filePath);
  if (actual !== expected) {
    throw new Error(
      `${assetName} does not match the signed manifest — the download is corrupt or was tampered with`);
  }
  return expected;
}

module.exports = {
  MANIFEST_NAME,
  SIGNATURE_NAME,
  SSHSIG_NAMESPACE,
  LEGACY_GPG_KEY,
  loadSigners,
  parseManifest,
  verifySshSignature,
  verifyGpgSignature,
  sha256File,
  fetchManifest,
  verifyAgainstManifest,
};
