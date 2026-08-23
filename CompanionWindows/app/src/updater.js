'use strict';
const { app, net, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const trust = require('./release-trust');
const buildInfo = require('./build-info');

/**
 * App self-update: check, tell the user, and only act when they say so.
 *
 * Notify-only on purpose. This process supervises a live VR session — the broker, the CloudXR
 * service, the sidecar and whatever game is running are all its children — so an update that
 * downloads and swaps itself in on its own schedule is an update that can end a session
 * someone is wearing. Nothing here downloads a byte until the user clicks.
 *
 * Every download is checked against the release's signed manifest (release-trust.js). A
 * release that has not been blessed yet is NOT offered: the installers carry no Authenticode
 * signature, so the manifest is the only thing standing between this code path and running an
 * arbitrary .exe that GitHub happened to serve.
 *
 * ORDERING RELEASES WITHOUT A COMPARABLE VERSION
 *
 * CI tags releases `0.1.0-<sha8>`. Those are not orderable: `0.1.0-abc12345` and
 * `0.1.0-def67890` say nothing about which came first, and semver would call both prerelease
 * builds of the same version. So "is there something newer" is answered with the release
 * timestamps GitHub keeps, never by comparing tag strings — and it takes TWO lookups, one for
 * /releases/latest and one for our own tag, because our own build's publication time is not
 * something we ship in build-info.json.
 *
 * That also gives the safe default for free: if our own tag is not a release at all (a local
 * build, a deleted release), the comparison cannot be made and no update is offered, rather
 * than every unrecognised build being told to "update" to whatever is currently latest.
 */

/** Matches the name CI gives the asset — see .github/workflows/build.yml's "Name the installer". */
function assetNameFor(version) {
  const arch = process.arch === 'arm64' ? 'arm64' : 'x64';
  return `LongwaveCompanion-${version}-${arch}-Setup.exe`;
}

function releasesUrl(pathSuffix) {
  return `https://api.github.com/repos/${buildInfo.repo}/releases${pathSuffix}`;
}

async function githubJson(url) {
  const res = await net.fetch(url, {
    headers: { 'User-Agent': 'Longwave-Companion', Accept: 'application/vnd.github+json' },
  });
  if (!res.ok) return { ok: false, status: res.status };
  return { ok: true, body: await res.json() };
}

// One check per app run unless explicitly forced. The GitHub API allows 60 unauthenticated
// requests an hour per IP and a check costs two of them; a UI that re-checks on every tab
// switch would burn that in a few minutes of ordinary clicking.
let cached = null;

/**
 * @returns {Promise<{available: boolean, reason?: string, ...}>} never throws — a failed
 * update check is not something to interrupt anyone over, so network and API failures come
 * back as a reason string for the UI to show quietly (or not at all).
 */
async function check({ force = false } = {}) {
  if (cached && !force) return cached;

  const result = await (async () => {
    if (process.platform !== 'win32') {
      return { available: false, reason: 'not-windows' };
    }
    if (buildInfo.version === 'dev') {
      // A dev build has no release of its own to compare against, and updating it would
      // replace a working tree's build with a published one. Never offer it.
      return { available: false, reason: 'dev-build', currentVersion: 'dev' };
    }

    let latest;
    try {
      const res = await githubJson(releasesUrl('/latest'));
      if (!res.ok) return { available: false, reason: `http-${res.status}` };
      latest = res.body;
    } catch (e) {
      return { available: false, reason: 'network-error', message: e.message };
    }

    if (latest.tag_name === buildInfo.version) {
      return { available: false, reason: 'up-to-date', currentVersion: buildInfo.version };
    }

    // Our own release, purely for its publication time.
    const mine = await githubJson(releasesUrl(`/tags/${encodeURIComponent(buildInfo.version)}`));
    if (!mine.ok) {
      return { available: false, reason: 'current-release-unknown', currentVersion: buildInfo.version };
    }
    if (!(new Date(latest.published_at) > new Date(mine.body.published_at))) {
      // Latest is older than us — this build is ahead of the channel (a re-tag, a deleted
      // release, or a build from a branch). Offering a "downgrade" here would be wrong.
      return { available: false, reason: 'up-to-date', currentVersion: buildInfo.version };
    }

    const assetName = assetNameFor(latest.tag_name);
    const asset = (latest.assets || []).find((a) => a.name === assetName);
    if (!asset) {
      // The Windows matrix has fail-fast off, so one architecture can be missing from a
      // release the other architecture is present in. Not an error, just nothing to offer.
      return {
        available: false,
        reason: 'asset-missing',
        currentVersion: buildInfo.version,
        version: latest.tag_name,
      };
    }

    return {
      available: true,
      currentVersion: buildInfo.version,
      version: latest.tag_name,
      publishedAt: latest.published_at,
      notes: typeof latest.body === 'string' ? latest.body : '',
      htmlUrl: latest.html_url,
      assetName,
      downloadUrl: asset.browser_download_url,
      size: asset.size,
    };
  })();

  cached = result;
  return result;
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
 * Downloads the update and proves it came from the signing key before returning its path.
 * Deletes the file on any failure, so a rejected download can never be left lying around for
 * something else to pick up and run.
 */
async function downloadAndVerify(onProgress) {
  const info = await check();
  if (!info.available) throw new Error(`no update to download (${info.reason})`);

  onProgress?.({ phase: 'verifying-release' });
  const manifest = await trust.fetchManifest(buildInfo.repo, info.version);
  if (!manifest) {
    // Deliberately a hard stop rather than a fallback to a bare checksum or to nothing: the
    // whole reason this path is allowed to run an unsigned .exe is the manifest. A release
    // still awaiting its blessing is a release this app waits for.
    throw new Error(
      `${info.version} has no signed SHA256SUMS yet — it has not been blessed with the release `
      + `key. Nothing was downloaded.`);
  }

  const dest = path.join(app.getPath('temp'), info.assetName);
  onProgress?.({ phase: 'downloading', received: 0, total: info.size });
  try {
    await downloadToFile(info.downloadUrl, dest, onProgress);
    onProgress?.({ phase: 'verifying' });
    await trust.verifyAgainstManifest(manifest, info.assetName, dest);
  } catch (e) {
    fs.rm(dest, { force: true }, () => {});
    throw e;
  }
  onProgress?.({ phase: 'ready', path: dest });
  return { path: dest, version: info.version };
}

/**
 * Hands the verified installer over and gets out of its way.
 *
 * Launched with no arguments — the full interactive NSIS UI, not a silent `/S` reinstall.
 * The installer is where the PCVR opt-in checkbox lives (buildResources/installer.nsh), so a
 * silent update would quietly decide that question on the user's behalf, and it is also
 * per-machine, which means a UAC prompt the user should see attached to a visible installer
 * rather than to nothing.
 *
 * The app must be gone before NSIS tries to replace its files, hence quit() immediately after
 * spawning, `detached` so the installer outlives us, and `unref` so our event loop is not held
 * open waiting for it.
 */
function installAndQuit(installerPath) {
  if (!fs.existsSync(installerPath)) throw new Error(`installer is gone: ${installerPath}`);
  const child = spawn(installerPath, [], { detached: true, stdio: 'ignore' });
  child.unref();
  app.quit();
}

function openReleasePage(info) {
  return shell.openExternal(info?.htmlUrl || `https://github.com/${buildInfo.repo}/releases`);
}

module.exports = {
  assetNameFor,
  check,
  downloadAndVerify,
  installAndQuit,
  openReleasePage,
  currentVersion: buildInfo.version,
};
