'use strict';
const { app, net } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { execFile, execFileSync } = require('child_process');
const trust = require('./release-trust');
const buildInfo = require('./build-info');

/**
 * The closed-source PCVR bundle (LongwavePCVRHost.exe + the SessionBroker/OpenXRLayer native
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
const DRIVER_DIR = path.join(INSTALL_ROOT, 'drivers');
const VIGEMBUS_INSTALLER = 'ViGEmBus_1.22.0_x64_x86_arm64.exe';
const VIGEMBUS_SHA256 = '89220a7865076b342892f98865f3499fb7c4cfd673159e89d352c360fd014c6a';
const VERSION_FILE = path.join(INSTALL_ROOT, 'installed-version.json');
// Deliberately OUTSIDE INSTALL_ROOT: downloadAndInstall() clears that directory on every
// install, and a record of "this user has been asked" must not be erased by the very act of
// answering yes.
const OPT_IN_HANDLED_FILE = path.join(app.getPath('userData'), 'pcvr-optin-handled.json');

/**
 * Whether this machine can host PCVR at all.
 *
 * Windows on x64, and nothing else. Not a policy choice — CloudXR ships x64-only, and the
 * whole feature needs an NVIDIA RTX GPU, which no Windows-on-ARM machine has. CI does build an
 * arm64 installer (Snapdragon X laptops are common, and the hotspot and screen-streaming
 * features work fine there), so without this check an arm64 user gets a PCVR tab that asks
 * GitHub for `Longwave-PCVR-Bundle-win-arm64.zip` — an asset nothing builds and nothing can —
 * and is told "not published yet for this app version. Check back after it's uploaded." That
 * is a promise the product cannot keep. Hiding the feature is the honest answer.
 *
 * LONGWAVE_FORCE_PCVR=1 overrides it, for developing the PCVR surfaces on a machine that could
 * never run them — an arm64 Mac being the case that matters. It forces the UI to render; it
 * cannot make a bundle exist, so the tab shows its download banner and the download itself
 * fails at the asset lookup. That is enough to work on the chrome, the banners, the version
 * pairing and the opt-in flow. Same shape as the LONGWAVE_BUILD_* overrides in build-info.js,
 * and like those it is an identity override only: nothing here relaxes a signature check.
 */
function isSupportedHost() {
  if (process.env.LONGWAVE_FORCE_PCVR === '1') return true;
  return process.platform === 'win32' && process.arch === 'x64';
}

/**
 * Always the x64 bundle — the only one that exists, and the only one that could. The arm64
 * name this used to derive from `process.arch` was a dead branch pointing at an asset nothing
 * builds; isSupportedHost() now rules that host out before anything asks. Keeping it x64 also
 * makes LONGWAVE_FORCE_PCVR useful on an arm64 Mac: the lookup resolves to a real asset that
 * can be downloaded and inspected, rather than 404-ing on a name that never existed.
 */
function assetNameForArch() {
  return 'Longwave-PCVR-Bundle-win-x64.zip';
}

function installedVersion() {
  try { return JSON.parse(fs.readFileSync(VERSION_FILE, 'utf8')).version; } catch { return null; }
}

function isInstalled() {
  return fs.existsSync(path.join(HOST_DIR, 'LongwavePCVRHost.exe'));
}

function vigemBusStatus() {
  const installerPath = path.join(DRIVER_DIR, VIGEMBUS_INSTALLER);
  let installed = false;
  if (process.platform === 'win32') {
    try {
      execFileSync('sc.exe', ['query', 'ViGEmBus'], { stdio: 'ignore', windowsHide: true });
      installed = true;
    } catch {
      installed = false;
    }
  }
  return {
    installed,
    bundled: fs.existsSync(installerPath),
    installerPath,
  };
}

function sha256FileSync(filePath) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(filePath));
  return hash.digest('hex');
}

function installVigemBus() {
  const status = vigemBusStatus();
  if (status.installed) return Promise.resolve(status);
  if (process.platform !== 'win32') {
    return Promise.reject(new Error('ViGEmBus can only be installed on Windows.'));
  }
  if (!status.bundled) {
    return Promise.reject(new Error('The ViGEmBus installer is not present in this PCVR bundle.'));
  }
  const actual = sha256FileSync(status.installerPath);
  if (actual !== VIGEMBUS_SHA256) {
    return Promise.reject(new Error('The bundled ViGEmBus installer failed its checksum.'));
  }

  return new Promise((resolve, reject) => {
    const escapedPath = status.installerPath.replace(/'/g, "''");
    const script = `$p = Start-Process -FilePath '${escapedPath}' -Verb RunAs -Wait -PassThru; exit $p.ExitCode`;
    const encoded = Buffer.from(script, 'utf16le').toString('base64');
    execFile('powershell.exe', ['-NoProfile', '-EncodedCommand', encoded],
      { windowsHide: true }, (err, stdout, stderr) => {
        if (err) {
          reject(new Error(`ViGEmBus installation failed: ${stderr || err.message}`));
          return;
        }
        const updated = vigemBusStatus();
        if (!updated.installed) {
          reject(new Error('The installer finished, but Windows does not report ViGEmBus installed.'));
          return;
        }
        resolve(updated);
      });
  });
}

/**
 * The NVIDIA CloudXR Virtual Audio Driver — the only way the headset microphone reaches
 * Windows. visionOS forwards the mic for every session and the runtime creates a microphone
 * stream for it, but that stream is pushed into this driver's capture endpoint and nowhere
 * else: without it the server log reads `nvAudCapRegisterEndpoint failed (13)` at start and
 * `total bytes captured: 0` at teardown, and no game hears a word. NVIDIA: "install the
 * driver before starting the runtime."
 *
 * It is a root-enumerated virtual device, so `pnputil /add-driver` would only stage the
 * package. The bundled script creates the device node and binds the INF (the `devcon
 * install` sequence via SetupAPI); it needs one UAC prompt, like ViGEmBus. The INF ships
 * inside the CloudXR redistributable already in the bundle, under
 * host/Server/releases/<version>/CloudXRVirtualAudioDriver/.
 */
const AUDIO_DRIVER_SCRIPT = path.join(HOST_DIR, 'install-cloudxr-audio-driver.ps1');

function cloudXRAudioDriverDir() {
  const releases = path.join(HOST_DIR, 'Server', 'releases');
  let versions = [];
  try { versions = fs.readdirSync(releases); } catch { return null; }
  for (const version of versions.sort().reverse()) {
    const dir = path.join(releases, version, 'CloudXRVirtualAudioDriver');
    if (fs.existsSync(path.join(dir, 'nvcloudxrvad.inf'))) return dir;
  }
  return null;
}

function runAudioDriverScript(args, { elevated } = {}) {
  return new Promise((resolve, reject) => {
    const scriptArgs = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', AUDIO_DRIVER_SCRIPT, ...args];
    if (!elevated) {
      execFile('powershell.exe', scriptArgs, { windowsHide: true }, (err, stdout, stderr) => {
        if (err) { reject(new Error(stderr || err.message)); return; }
        resolve(stdout);
      });
      return;
    }
    // `-Verb RunAs` raises the UAC prompt; the exit code is the only thing that comes back
    // across the elevation boundary, so the caller re-reads the status afterwards.
    const quoted = scriptArgs.map((a) => `'${a.replace(/'/g, "''")}'`).join(',');
    const script = `$p = Start-Process -FilePath 'powershell.exe' -ArgumentList @(${quoted}) -Verb RunAs -Wait -PassThru -WindowStyle Hidden; exit $p.ExitCode`;
    const encoded = Buffer.from(script, 'utf16le').toString('base64');
    execFile('powershell.exe', ['-NoProfile', '-EncodedCommand', encoded],
      { windowsHide: true }, (err, stdout, stderr) => {
        if (err) { reject(new Error(stderr || err.message)); return; }
        resolve(stdout);
      });
  });
}

async function cloudXRAudioDriverStatus() {
  const driverDir = cloudXRAudioDriverDir();
  const bundled = driverDir !== null && fs.existsSync(AUDIO_DRIVER_SCRIPT);
  const status = { installed: false, bundled, driverDir };
  if (process.platform !== 'win32' || !fs.existsSync(AUDIO_DRIVER_SCRIPT)) return status;
  try {
    const out = await runAudioDriverScript(['-Status']);
    const parsed = JSON.parse(out.trim().split(/\r?\n/).pop());
    status.installed = parsed.installed === true;
    status.deviceStatus = parsed.status ?? null;
  } catch (e) {
    status.error = e.message;
  }
  return status;
}

async function installCloudXRAudioDriver() {
  const status = await cloudXRAudioDriverStatus();
  if (status.installed) return status;
  if (process.platform !== 'win32') {
    throw new Error('The CloudXR audio driver can only be installed on Windows.');
  }
  if (!status.bundled) {
    throw new Error('This PCVR bundle does not contain the CloudXR audio driver.');
  }
  try {
    await runAudioDriverScript(['-DriverDir', status.driverDir], { elevated: true });
  } catch (e) {
    throw new Error(`CloudXR audio driver installation failed: ${e.message}`);
  }
  const updated = await cloudXRAudioDriverStatus();
  if (!updated.installed) {
    throw new Error('The installer finished, but Windows does not report the NVIDIA CloudXR audio device.');
  }
  return updated;
}

/**
 * Asks GitHub whether a PCVR bundle exists for this build's own release tag. Unauthenticated
 * (60 req/hr per IP) — fine for a manual, occasional check, never polled in a loop.
 */
async function checkAvailability() {
  if (!isSupportedHost()) {
    // Before the network call, and before the dev-build check: on a machine that cannot run
    // this, whether a bundle exists is not an interesting question.
    return { available: false, reason: 'unsupported-host', installedVersion: installedVersion() };
  }
  if (buildInfo.version === 'dev') {
    return { available: false, reason: 'dev-build', installedVersion: installedVersion() };
  }
  let res;
  try {
    res = await net.fetch(
      `https://api.github.com/repos/${buildInfo.repo}/releases/tags/${buildInfo.version}`,
      { headers: { 'User-Agent': 'Longwave-Companion', Accept: 'application/vnd.github+json' } },
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

/**
 * Verifies the bundle's own detached GPG signature. The signing key and the reasoning behind
 * it now live in release-trust.js, which the app updater shares — see that file's header for
 * why a YubiKey-held key is the anchor rather than a code-signing certificate.
 *
 * Throws on a missing or invalid signature; callers only reach here once they know the .asc
 * asset exists, so "present but invalid" is always a hard failure, never a silent skip.
 */
async function verifyGpgSignature(filePath, signatureArmored) {
  await trust.verifyGpgSignature(await fs.promises.readFile(filePath), signatureArmored);
}

/**
 * Points LIBOVR_DLL_DIR at the bundle's bridge directory.
 *
 * This is the step whose absence broke every PCVR title on the dev host on 2026-08-23, and
 * it had never been implemented for a packaged install at all — meaning a public user who
 * downloaded the bundle would have had a complete, verified, correctly registered PCVR stack
 * that could not start a single game.
 *
 * VDXR is the OpenXR runtime games get, and VDXR has no headset of its own: it reaches ours
 * by loading a LibOVR-shaped shim, which the Oculus CAPI shim compiled into it searches for
 * in LIBOVR_DLL_DIR before anywhere else. Without the variable, xrGetSystem fails with
 * XR_ERROR_FORM_FACTOR_UNAVAILABLE and the only clue is a VDXR log line reading "Virtual
 * Desktop Server is not running" — which names neither the variable nor the directory nor
 * even the right subsystem.
 *
 * Written to the registry at USER scope, and nothing else:
 *   - The registry rather than this process's environment, because a process environment
 *     block is a snapshot taken at creation. That distinction has bitten this project twice
 *     (see HOST_PROVISIONING.md, "the stale-environment trap"); the PCVR host reads the
 *     registry live on every launch, so a value written here is in effect immediately with
 *     nothing to restart.
 *   - User rather than machine, so it needs no elevation, and so it cannot outlive this
 *     user's install or fight with another user's on the same PC.
 *   - No WM_SETTINGCHANGE broadcast, deliberately: every consumer that matters
 *     (GameLibrary.ApplyShimDirectory) reads the registry rather than inheriting, so the
 *     broadcast would buy nothing but a reason to think inheritance works.
 */
function registerShimDirectory() {
  try {
    execFileSync('reg', ['add', 'HKCU\\Environment', '/v', 'LIBOVR_DLL_DIR', '/t', 'REG_SZ',
                         '/d', BRIDGE_DIR, '/f'], { stdio: 'ignore' });
    return { ok: true, directory: BRIDGE_DIR };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

/**
 * Gives LIBOVR_DLL_DIR back on uninstall — but only when it still names OUR bridge directory.
 * A developer running from a source checkout points it at their own build output, and
 * uninstalling a downloaded bundle has no business deleting that.
 */
function unregisterShimDirectory() {
  try {
    const out = execFileSync('reg', ['query', 'HKCU\\Environment', '/v', 'LIBOVR_DLL_DIR'],
                             { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    const match = out.match(/LIBOVR_DLL_DIR\s+REG_SZ\s+(.+)/);
    const current = match ? match[1].trim() : null;
    if (!current || current.toLowerCase() !== BRIDGE_DIR.toLowerCase()) return { ok: true, kept: current };
    execFileSync('reg', ['delete', 'HKCU\\Environment', '/v', 'LIBOVR_DLL_DIR', '/f'],
                 { stdio: 'ignore' });
    return { ok: true, cleared: true };
  } catch {
    return { ok: true };   // absent already, or no registry access; nothing to undo
  }
}

/**
 * Whether the installer's PCVR checkbox was ticked (buildResources/installer.nsh).
 *
 * Read from HKLM rather than passed on a command line or dropped as a file in $INSTDIR,
 * because the answer has to survive the installer exiting and the app being started later by
 * a shortcut, an update, or a different user. `reg` inherits this process's registry view, and
 * this process is 64-bit (or arm64), so it reads the same view the installer explicitly wrote
 * to with SetRegView 64 — the two halves of that pairing must not be changed independently.
 */
function installerOptIn() {
  try {
    const out = execFileSync(
      'reg', ['query', 'HKLM\\Software\\Longwave\\Companion', '/v', 'PcvrOptIn'],
      // stderr ignored, not inherited: an absent key is the NORMAL case here (any source
      // checkout, and any install predating the checkbox), and execFileSync passes a child's
      // stderr straight to ours unless told not to. That put "ERROR: The system was unable to
      // find the specified registry key or value." in the app log on every launch of a dev
      // host — an alarming line for an expected miss that this function already handles by
      // returning false.
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    // REG_DWORD prints as 0x1 / 0x0.
    return /PcvrOptIn\s+REG_DWORD\s+0x1\b/i.test(out);
  } catch {
    return false;   // key absent: an install that predates the checkbox, or the box was clear
  }
}

/**
 * True when the app should offer the PCVR download unprompted: the box was ticked, nothing is
 * installed yet, and this user has not already been asked.
 *
 * The "already asked" half is per-user state in userData, not a write back to HKLM, because
 * the app runs unelevated and cannot clear a machine-wide value — and should not, since two
 * users of the same PC each need to be asked once. Recorded when the offer is made rather than
 * when it succeeds, so declining is remembered too and the prompt does not return on every
 * launch.
 */
function optInPending() {
  if (!isSupportedHost()) return false;
  if (isInstalled()) return false;
  if (fs.existsSync(OPT_IN_HANDLED_FILE)) return false;
  return installerOptIn();
}

function markOptInHandled(outcome) {
  try {
    fs.mkdirSync(path.dirname(OPT_IN_HANDLED_FILE), { recursive: true });
    fs.writeFileSync(OPT_IN_HANDLED_FILE, JSON.stringify({
      outcome, at: new Date().toISOString(),
    }));
  } catch { /* best effort — the worst case is being asked once more */ }
}

/**
 * True when a bundle is installed but was built for a different app release than the one now
 * running — which is what an app update leaves behind. The bundle and the app talk over a pipe
 * protocol with no version negotiation, so the pairing is by release tag and a mismatch means
 * the PCVR stack must not be started until the matching bundle is fetched.
 */
function needsRefresh() {
  if (!isInstalled()) return false;
  if (buildInfo.version === 'dev') return false;   // a dev build pins nothing
  return installedVersion() !== buildInfo.version;
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

  let verifiedBy = null;
  const tmpZip = path.join(app.getPath('temp'), `longwave-pcvr-${process.pid}.zip`);
  onProgress?.({ phase: 'downloading', received: 0, total: info.size });
  await downloadToFile(info.downloadUrl, tmpZip, onProgress);

  try {
    // Verification. At least one of these MUST succeed — falling out of the bottom having
    // checked nothing is a hard failure, not a quiet install.
    //
    //   1. The release's signed SHA256SUMS: one signature covering every asset on the
    //      release, and the same anchor the app updater uses (release-trust.js), so there is
    //      one thing to reason about rather than a different story per artifact.
    //   2. This bundle's own detached .asc — the original mechanism, by the same YubiKey, so
    //      no weaker per signature. Kept for bundles published before the manifest existed,
    //      and reached when a manifest exists but predates this bundle's upload (the release
    //      is blessed once, and the bundle is attached separately and by hand afterwards).
    //   3. The .sha256 sidecar, which proves only that the download matches whatever was
    //      uploaded. No use against a compromised release, which is why it is last.
    //
    // fetchManifest is NOT wrapped in a catch: it returns null when the release simply has no
    // manifest, and throws only when a manifest is present and its signature does not check
    // out. Swallowing that throw would let a tampered manifest silently downgrade us to a
    // weaker check, which is the one thing this cascade must never do.
    const manifest = await trust.fetchManifest(buildInfo.repo, info.version);
    if (manifest && manifest.entries.has(info.assetName)) {
      onProgress?.({ phase: 'verifying' });
      await trust.verifyAgainstManifest(manifest, info.assetName, tmpZip);
      verifiedBy = 'release-manifest';
    } else if (info.signatureUrl) {
      onProgress?.({ phase: 'verifying' });
      const sigRes = await net.fetch(info.signatureUrl);
      if (!sigRes.ok) throw new Error(`could not fetch signature: HTTP ${sigRes.status}`);
      try {
        await verifyGpgSignature(tmpZip, await sigRes.text());
      } catch (e) {
        throw new Error(
          `signature verification failed — the download is corrupt or was tampered with: ${e.message}`);
      }
      verifiedBy = 'bundle-signature';
    } else if (info.checksumUrl) {
      onProgress?.({ phase: 'verifying' });
      const checksumRes = await net.fetch(info.checksumUrl);
      if (!checksumRes.ok) throw new Error(`could not fetch checksum: HTTP ${checksumRes.status}`);
      const expected = (await checksumRes.text()).trim().split(/\s+/)[0].toLowerCase();
      const actual = await trust.sha256File(tmpZip);
      if (expected !== actual) {
        throw new Error('checksum mismatch — the download is corrupt or was tampered with');
      }
      verifiedBy = 'checksum';
    }
    if (!verifiedBy) {
      // Reachable only if a release carries the bundle with no manifest, no .asc and no
      // .sha256 — i.e. someone uploaded it by hand. Before this check that combination
      // installed and ran a closed-source binary on nothing but TLS to GitHub.
      throw new Error(
        `${info.assetName} on ${info.version} has nothing to verify it against — no signed `
        + `SHA256SUMS, no .asc, no .sha256. Refusing to install it.`);
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
  // Before the version file is written, so a failure here cannot leave the bundle recorded as
  // installed-and-ready while games would still fail at xrGetSystem.
  const shimResult = registerShimDirectory();

  fs.writeFileSync(VERSION_FILE, JSON.stringify({
    version: info.version,
    installedAt: new Date().toISOString(),
  }));
  onProgress?.({ phase: 'done' });
  return { version: info.version, layerResult, shimResult, verifiedBy };
}

function uninstall() {
  unregisterShimDirectory();
  fs.rmSync(INSTALL_ROOT, { recursive: true, force: true });
}

module.exports = {
  INSTALL_ROOT,
  HOST_DIR,
  BRIDGE_DIR,
  DRIVER_DIR,
  isSupportedHost,
  checkAvailability,
  downloadAndInstall,
  isInstalled,
  installedVersion,
  needsRefresh,
  installerOptIn,
  optInPending,
  markOptInHandled,
  registerShimDirectory,
  unregisterShimDirectory,
  vigemBusStatus,
  installVigemBus,
  cloudXRAudioDriverStatus,
  installCloudXRAudioDriver,
  uninstall,
};
