'use strict';
const { app, net } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { execFile } = require('child_process');
const openpgp = require('openpgp');
const buildInfo = require('./build-info.json');

// The public half of the Ixion YubiKey OpenPGP key (ed25519) that signs each PCVR bundle —
// verified here with openpgp.js rather than shelling out to gpg.exe, which most end-user
// Windows machines simply don't have installed. Committed to the public repo on purpose:
// this is exactly what lets anyone verify a release independently, not just this app.
const SIGNING_PUBLIC_KEY = fs.readFileSync(path.join(__dirname, 'pcvr-signing-key.asc'), 'utf8');

/**
 * The closed-source PCVR bundle (VisionVNCPCVRHost.exe + the SessionBroker/OpenXRLayer native
 * binaries + the CloudXR SDK redistributable) is never shipped in the public installer. It is
 * downloaded on demand from a GitHub Release asset attached to *this exact build's own release
 * tag* — never `/releases/latest` — because the tag is the only thing that guarantees the pipe
 * protocol on both ends actually matches. CI creates the release and uploads the public
 * installers; the closed-source bundle is uploaded to that same tag separately, by hand, from a
 * machine that can build it (see scripts/package-pcvr-bundle.sh).
 */
const INSTALL_ROOT = path.join(app.getPath('userData'), 'pcvr-bundle');
const HOST_DIR = path.join(INSTALL_ROOT, 'host');
const BRIDGE_DIR = path.join(INSTALL_ROOT, 'bridge');
const VERSION_FILE = path.join(INSTALL_ROOT, 'installed-version.json');

function assetNameForArch() {
  return `VisionVNC-PCVR-Bundle-${process.arch === 'arm64' ? 'win-arm64' : 'win-x64'}.zip`;
}

function installedVersion() {
  try { return JSON.parse(fs.readFileSync(VERSION_FILE, 'utf8')).version; } catch { return null; }
}

function isInstalled() {
  return fs.existsSync(path.join(HOST_DIR, 'VisionVNCPCVRHost.exe'));
}

/**
 * Asks GitHub whether a PCVR bundle exists for this build's own release tag. Unauthenticated
 * (60 req/hr per IP) — fine for a manual, occasional check, never polled in a loop.
 */
async function checkAvailability() {
  if (buildInfo.version === 'dev') {
    return { available: false, reason: 'dev-build', installedVersion: installedVersion() };
  }
  let res;
  try {
    res = await net.fetch(
      `https://api.github.com/repos/${buildInfo.repo}/releases/tags/${buildInfo.version}`,
      { headers: { 'User-Agent': 'VisionVNC-Companion', Accept: 'application/vnd.github+json' } },
    );
  } catch (e) {
    return { available: false, reason: 'network-error', message: e.message, installedVersion: installedVersion() };
  }
  if (!res.ok) {
    return {
      available: false,
      reason: res.status === 404 ? 'release-not-found' : `http-${res.status}`,
      installedVersion: installedVersion(),
    };
  }
  const release = await res.json();
  const assetName = assetNameForArch();
  const assets = Array.isArray(release.assets) ? release.assets : [];
  const asset = assets.find((a) => a.name === assetName);
  if (!asset) {
    return { available: false, reason: 'asset-missing', installedVersion: installedVersion() };
  }
  const checksumAsset = assets.find((a) => a.name === `${assetName}.sha256`);
  const signatureAsset = assets.find((a) => a.name === `${assetName}.asc`);
  return {
    available: true,
    version: buildInfo.version,
    installedVersion: installedVersion(),
    upToDate: installedVersion() === buildInfo.version,
    size: asset.size,
    assetName,
    downloadUrl: asset.browser_download_url,
    checksumUrl: checksumAsset ? checksumAsset.browser_download_url : null,
    signatureUrl: signatureAsset ? signatureAsset.browser_download_url : null,
  };
}

async function downloadToFile(url, destPath, onProgress) {
  const res = await net.fetch(url);
  if (!res.ok) throw new Error(`download failed: HTTP ${res.status}`);
  const total = Number(res.headers.get('content-length') || 0);
  let received = 0;
  const out = fs.createWriteStream(destPath);
  const reader = res.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    received += value.length;
    out.write(Buffer.from(value));
    if (onProgress) onProgress({ phase: 'downloading', received, total });
  }
  await new Promise((resolve, reject) => out.end((err) => (err ? reject(err) : resolve())));
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
 * Verifies the bundle's detached GPG signature against the embedded public key. Stronger than
 * the sha256 sidecar: a checksum only proves the download matches whatever was uploaded, while
 * this proves it was signed by a key that lives on a YubiKey never exposed to CI or the release
 * pipeline — so it also covers a compromised GitHub account/token, not just transport corruption.
 * Throws on a missing or invalid signature; callers only call this once they know the .asc asset
 * exists, so "present but invalid" is always a hard failure, never a silent skip.
 */
async function verifyGpgSignature(filePath, signatureArmored) {
  const publicKey = await openpgp.readKey({ armoredKey: SIGNING_PUBLIC_KEY });
  const message = await openpgp.createMessage({ binary: await fs.promises.readFile(filePath) });
  const signature = await openpgp.readSignature({ armoredSignature: signatureArmored });
  const { signatures } = await openpgp.verify({ message, signature, verificationKeys: publicKey });
  await signatures[0].verified; // rejects if the signature does not check out
}

/**
 * Windows 10 1803+ ships bsdtar as tar.exe, which — unlike GNU tar — also unpacks .zip. Same
 * trick deploy-windows-companion.sh already relies on to avoid an npm zip dependency here.
 */
function extractZip(zipPath, destDir) {
  return new Promise((resolve, reject) => {
    fs.mkdirSync(destDir, { recursive: true });
    execFile('tar.exe', ['-xf', zipPath, '-C', destDir], (err, stdout, stderr) => {
      if (err) reject(new Error(`extraction failed: ${stderr || err.message}`));
      else resolve();
    });
  });
}

/**
 * Registers the controller-bridge implicit OpenXR API layer machine-wide. This is the one step
 * in the whole flow that needs admin, so it runs through `Start-Process -Verb RunAs`, which
 * raises the normal Windows UAC consent prompt — no bundled elevation helper, no extra
 * dependency. The command is base64/UTF-16LE encoded via -EncodedCommand so the layer directory
 * path (which can contain spaces, e.g. under "Local Settings") never has to survive quoting.
 */
function installApiLayerElevated(layerDir) {
  return new Promise((resolve, reject) => {
    const scriptPath = path.join(layerDir, 'install-layer.ps1');
    if (!fs.existsSync(scriptPath)) {
      resolve({ skipped: true, reason: 'install-layer.ps1 not found in bundle' });
      return;
    }
    const inner = `& '${scriptPath}' -LayerDir '${layerDir}'`;
    const encoded = Buffer.from(inner, 'utf16le').toString('base64');
    execFile('powershell.exe', [
      '-NoProfile', '-Command',
      `Start-Process powershell -ArgumentList '-NoProfile','-EncodedCommand','${encoded}' -Verb RunAs -Wait`,
    ], (err, stdout, stderr) => {
      if (err) reject(new Error(`layer registration failed: ${stderr || err.message}`));
      else resolve({ skipped: false });
    });
  });
}

/**
 * Full download -> verify -> extract -> register flow. onProgress is called with
 * {phase: 'downloading'|'verifying'|'extracting'|'registering'|'done', ...}. Throws on any
 * failure; the install root is left in whatever partial state it was in — the extraction step
 * always starts by clearing it, so a failed run is cleaned up by the next attempt, not left as
 * something that looks half-installed.
 */
async function downloadAndInstall(onProgress) {
  const info = await checkAvailability();
  if (!info.available) throw new Error(`PCVR bundle unavailable: ${info.reason}`);

  const tmpZip = path.join(app.getPath('temp'), `visionvnc-pcvr-${process.pid}.zip`);
  onProgress?.({ phase: 'downloading', received: 0, total: info.size });
  await downloadToFile(info.downloadUrl, tmpZip, onProgress);

  try {
    // The signature is the stronger guarantee (covers a compromised release, not just
    // transport corruption), so it wins when both are present; the checksum is the fallback
    // for a bundle uploaded before signing was wired in.
    if (info.signatureUrl) {
      onProgress?.({ phase: 'verifying' });
      const sigRes = await net.fetch(info.signatureUrl);
      if (!sigRes.ok) throw new Error(`could not fetch signature: HTTP ${sigRes.status}`);
      try {
        await verifyGpgSignature(tmpZip, await sigRes.text());
      } catch (e) {
        throw new Error(`signature verification failed — the download is corrupt or was tampered with: ${e.message}`);
      }
    } else if (info.checksumUrl) {
      onProgress?.({ phase: 'verifying' });
      const checksumRes = await net.fetch(info.checksumUrl);
      if (!checksumRes.ok) throw new Error(`could not fetch checksum: HTTP ${checksumRes.status}`);
      const expected = (await checksumRes.text()).trim().split(/\s+/)[0].toLowerCase();
      const actual = await sha256File(tmpZip);
      if (expected !== actual) {
        throw new Error('checksum mismatch — the download is corrupt or was tampered with');
      }
    }

    onProgress?.({ phase: 'extracting' });
    fs.rmSync(INSTALL_ROOT, { recursive: true, force: true });
    await extractZip(tmpZip, INSTALL_ROOT);
  } finally {
    fs.rm(tmpZip, { force: true }, () => {});
  }

  onProgress?.({ phase: 'registering' });
  const layerResult = await installApiLayerElevated(BRIDGE_DIR)
    .catch((e) => ({ skipped: true, error: e.message }));

  fs.writeFileSync(VERSION_FILE, JSON.stringify({
    version: info.version,
    installedAt: new Date().toISOString(),
  }));
  onProgress?.({ phase: 'done' });
  return { version: info.version, layerResult };
}

function uninstall() {
  fs.rmSync(INSTALL_ROOT, { recursive: true, force: true });
}

module.exports = {
  INSTALL_ROOT,
  HOST_DIR,
  BRIDGE_DIR,
  checkAvailability,
  downloadAndInstall,
  isInstalled,
  installedVersion,
  uninstall,
};
