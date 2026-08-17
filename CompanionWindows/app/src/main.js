'use strict';
const { app, BrowserWindow, ipcMain, dialog, shell, Notification } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { spawn, execFile } = require('child_process');
const { HotspotClient, PCVR_PIPE_PATH } = require('./pipe-client');
const { tailscaleStatus, checkPath } = require('./tailscale');
const { Supervisor } = require('./supervisor');
const { ControlServer } = require('./control-server');
const pcvrInstaller = require('./pcvr-installer');

let mainWindow = null;
let pairingWindow = null;
let noticesWindow = null;
let backendProc = null;
let pcvrHostProc = null;
let supervisor = null;
let controlServer = null;
let lastFoveatedStatus = null;
let pairingKey = null;
let dismissedPairingKey = null;
let pairingRevealed = false;
let quitInProgress = false;
let allowQuit = false;
let stackOperationTail = Promise.resolve();
// The public backend (hotspot, native mac streaming) — always present.
const client = new HotspotClient();
// The closed-source CloudXR/Foveated host — a separate process with its own pipe, present
// only when the user has installed it. Its own connect/reconnect loop already degrades to
// "never connects" when the exe or the pipe is missing, so no feature-detection is needed
// beyond checking pcvrClient.connected.
const pcvrClient = new HotspotClient(PCVR_PIPE_PATH);
// Foveated*/Games* methods live on the PCVR host's pipe; everything else (hotspot, native
// screen streaming, Ping) is the public backend. Method names are unique across both pipes
// by construction, so a prefix check is unambiguous.
function routeClientFor(method) {
  return method.startsWith('Foveated') || method.startsWith('Games') ? pcvrClient : client;
}
const gotSingleInstanceLock = app.requestSingleInstanceLock();

if (!gotSingleInstanceLock) {
  app.quit();
}

function withTimeout(promise, timeoutMs, label) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out`)), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/**
 * Where the host-built PCVR binaries live: the broker, the gaze-fix injector, and the OpenXR
 * controller-bridge layer DLL. The on-demand download (pcvr-installer.js) is the path a real
 * user install takes; the dev-checkout path is only for building SessionBroker/OpenXRLayer by
 * hand with CMake. LONGWAVE_BRIDGE_ROOT overrides it for a non-standard checkout.
 */
function resolveBridgeRoot() {
  const candidates = [
    process.env.LONGWAVE_BRIDGE_ROOT,
    pcvrInstaller.BRIDGE_DIR,
    app.isPackaged ? path.join(process.resourcesPath, 'bridge') : null,
    'C:\\dev\\Longwave-bridge\\SessionBroker\\build\\Release',
  ].filter(Boolean);
  return candidates.find((p) => fs.existsSync(p)) || null;
}

// Unambiguous WPA2 alphabet (mirrors the backend Tokens.cs — no 0/O/1/l/I).
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
function randomToken(len) {
  const bytes = crypto.randomBytes(len);
  let s = '';
  for (let i = 0; i < len; i++) s += ALPHABET[bytes[i] % ALPHABET.length];
  return s;
}

/** Locate the backend exe in packaged resources or the dev build output. */
function resolveBackendExe() {
  const name = 'LongwaveCompanionBackend.exe';
  const candidates = app.isPackaged
    ? [path.join(process.resourcesPath, 'backend', name)]
    : [
        path.join(__dirname, '..', '..', 'backend', 'bin', 'Release', 'net8.0-windows10.0.22621.0', 'publish', name),
        path.join(__dirname, '..', '..', 'backend', 'bin', 'Release', 'net8.0-windows10.0.22621.0', name),
      ];
  return candidates.find((p) => fs.existsSync(p)) || null;
}

/**
 * Locate the closed-source PCVR host exe. Absent in a public-only checkout/install — that is
 * the expected, common case, not an error, so callers just skip starting it.
 */
function resolvePcvrHostExe() {
  const name = 'LongwavePCVRHost.exe';
  const candidates = [
    path.join(pcvrInstaller.HOST_DIR, name),
    ...(app.isPackaged
      ? [path.join(process.resourcesPath, 'pcvr-host', name)]
      : [
          path.join(__dirname, '..', '..', '..', 'Longwave-PCVR-Host', 'bin', 'Release', 'net8.0-windows10.0.22621.0', 'publish', name),
          path.join(__dirname, '..', '..', '..', 'Longwave-PCVR-Host', 'bin', 'Release', 'net8.0-windows10.0.22621.0', name),
        ]),
  ];
  return candidates.find((p) => fs.existsSync(p)) || null;
}

/**
 * Start the backend as an interactive-session helper. Electron is asInvoker, so the child
 * stays in the same medium-integrity desktop session. If the backend is already running,
 * the spawn simply fails to bind the pipe and exits; we connect to whichever instance owns it.
 */
function startBackend() {
  if (process.env.LONGWAVE_NO_SPAWN === '1') return;
  const exe = resolveBackendExe();
  if (!exe) {
    console.warn('[main] backend exe not found; expecting an externally-run backend/service.');
    return;
  }
  console.log('[main] launching backend:', exe);
  /* Captured, not discarded. With stdio ignored, the backend we spawn writes nowhere at all
     — while logs\backend.log still holds whatever the last task-launched backend wrote, so
     it reads like a current log and is not one. That cost real time during a diagnosis:
     "Client disconnected (0 remain)" looked like live evidence and was hours stale. */
  let backendLog = null;
  try {
    const logPath = path.join(__dirname, '..', '..', 'logs', 'backend.log');
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    backendLog = fs.createWriteStream(logPath, { flags: 'w' });
    backendLog.on('error', (e) => {
      console.warn('[main] backend log unavailable:', e.message);
      backendLog = null;
    });
  } catch (e) {
    console.warn('[main] backend log unavailable:', e.message);
  }
  backendProc = spawn(exe, [], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  for (const stream of [backendProc.stdout, backendProc.stderr]) {
    // Read regardless of whether the log survived: an undrained pipe eventually blocks the
    // backend.
    stream.on('data', (chunk) => { if (backendLog) backendLog.write(chunk); });
  }
  backendProc.on('exit', (code) => {
    console.log('[main] backend exited with code', code);
    backendProc = null;
  });
  backendProc.on('error', (e) => console.error('[main] backend spawn error:', e.message));
}

/**
 * Start the PCVR host as a second interactive-session helper, same shape as startBackend.
 * A no-op (not an error) when the exe isn't found: that's every public-only install.
 */
function startPcvrHost() {
  if (process.env.LONGWAVE_NO_SPAWN === '1') return;
  const exe = resolvePcvrHostExe();
  if (!exe) {
    console.log('[main] PCVR host not installed; PCVR/game-library features stay hidden.');
    return;
  }
  console.log('[main] launching PCVR host:', exe);
  let hostLog = null;
  try {
    const logPath = path.join(__dirname, '..', '..', 'logs', 'pcvr-host.log');
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    hostLog = fs.createWriteStream(logPath, { flags: 'w' });
    hostLog.on('error', (e) => {
      console.warn('[main] PCVR host log unavailable:', e.message);
      hostLog = null;
    });
  } catch (e) {
    console.warn('[main] PCVR host log unavailable:', e.message);
  }
  pcvrHostProc = spawn(exe, [], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  for (const stream of [pcvrHostProc.stdout, pcvrHostProc.stderr]) {
    stream.on('data', (chunk) => { if (hostLog) hostLog.write(chunk); });
  }
  pcvrHostProc.on('exit', (code) => {
    console.log('[main] PCVR host exited with code', code);
    pcvrHostProc = null;
  });
  pcvrHostProc.on('error', (e) => console.error('[main] PCVR host spawn error:', e.message));
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1040,
    height: 760,
    minWidth: 880,
    minHeight: 640,
    title: 'Longwave Companion',
    icon: path.join(__dirname, '..', 'buildResources', 'icon.ico'),
    backgroundColor: '#1b1a18',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  mainWindow.removeMenu();
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  const send = (channel, payload) => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(channel, payload);
  };
  client.on('connected', () => send('connection', true));
  client.on('disconnected', () => send('connection', false));
  client.on('notify', (event, data) => send('notify', { event, data }));
  pcvrClient.on('connected', () => send('pcvr-connection', true));
  pcvrClient.on('disconnected', () => send('pcvr-connection', false));
  pcvrClient.on('notify', (event, data) => {
    if (event === 'foveated') {
      lastFoveatedStatus = data;
      syncPairingWindow(data);
    }
    // Its own event, not folded into 'foveated' above — that one is level-triggered
    // status pushed on state changes, this is edge-triggered, fired once per genuine
    // threshold crossing (see BandwidthMonitor.EvaluateThresholds on the host side),
    // which is what makes a toast here meaningful instead of firing on every push that
    // merely happens to still be over the cap.
    if (event === 'bandwidth') {
      new Notification({
        title: data.tier === 'stop' ? 'Bandwidth cap reached' : 'Bandwidth warning',
        body: `${data.usedGB.toFixed(1)} GB used this month (threshold: ${data.thresholdGB.toFixed(0)} GB)`,
      }).show();
    }
    send('notify', { event, data });
  });
  mainWindow.on('close', (event) => {
    if (allowQuit) return;
    event.preventDefault();
    requestQuit();
  });
}

function pairingStatusKey(status) {
  if (!status?.pairingRequired || (!status.qrPngDataUri && !status.qrPayload)) return null;
  return crypto.createHash('sha256')
    .update(status.qrPayload || status.qrPngDataUri)
    .digest('hex');
}

function sendPairingState() {
  if (!pairingWindow || pairingWindow.isDestroyed()) return;
  const hasPairing = pairingKey !== null && lastFoveatedStatus?.pairingRequired;
  pairingWindow.webContents.send('pairing-state', {
    available: hasPairing,
    revealed: hasPairing && pairingRevealed,
    qrPngDataUri: hasPairing && pairingRevealed
      ? (lastFoveatedStatus.qrPngDataUri || null)
      : null,
  });
}

function createPairingWindow() {
  if (pairingWindow && !pairingWindow.isDestroyed()) {
    sendPairingState();
    return;
  }

  pairingWindow = new BrowserWindow({
    width: 720,
    height: 760,
    minWidth: 600,
    minHeight: 660,
    title: 'Longwave Pairing Code',
    icon: path.join(__dirname, '..', 'buildResources', 'icon.ico'),
    backgroundColor: '#0a080c',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'pairing-preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  pairingWindow.removeMenu();
  pairingWindow.loadFile(path.join(__dirname, 'pairing', 'index.html'));
  pairingWindow.webContents.on('did-finish-load', sendPairingState);
  pairingWindow.on('closed', () => {
    if (pairingKey !== null) dismissedPairingKey = pairingKey;
    pairingWindow = null;
    pairingRevealed = false;
  });
}

/**
 * The notices file is the repo's own CompanionWindows/THIRD_PARTY_NOTICES.md, staged into
 * the app's resources at build time rather than copied into src/. One file, two readers —
 * a licence page that has drifted from the notices it claims to show is worse than none.
 */
function noticesPath() {
  return app.isPackaged
    ? path.join(process.resourcesPath, 'THIRD_PARTY_NOTICES.md')
    : path.join(__dirname, '..', '..', 'THIRD_PARTY_NOTICES.md');
}

function createNoticesWindow() {
  if (noticesWindow && !noticesWindow.isDestroyed()) {
    noticesWindow.focus();
    return;
  }
  noticesWindow = new BrowserWindow({
    width: 760,
    height: 820,
    minWidth: 520,
    minHeight: 400,
    title: 'Licences',
    icon: path.join(__dirname, '..', 'buildResources', 'icon.ico'),
    backgroundColor: '#1B1A18',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'notices-preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  noticesWindow.removeMenu();
  noticesWindow.loadFile(path.join(__dirname, 'renderer', 'notices.html'));
  noticesWindow.on('closed', () => { noticesWindow = null; });
}

function syncPairingWindow(status, forceShow = false) {
  const nextKey = pairingStatusKey(status);
  if (nextKey === null) {
    pairingKey = null;
    dismissedPairingKey = null;
    pairingRevealed = false;
    if (pairingWindow && !pairingWindow.isDestroyed()) pairingWindow.close();
    return;
  }

  const pairingChanged = nextKey !== pairingKey;
  if (pairingChanged) {
    pairingKey = nextKey;
    dismissedPairingKey = null;
    pairingRevealed = false;
  }

  if (forceShow) dismissedPairingKey = null;
  if (dismissedPairingKey === pairingKey) {
    sendPairingState();
    return;
  }

  createPairingWindow();
  if ((forceShow || pairingChanged) && pairingWindow && !pairingWindow.isDestroyed()) {
    if (pairingWindow.isMinimized()) pairingWindow.restore();
    pairingWindow.show();
    pairingWindow.focus();
  }
}

function focusMainWindow() {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
}

async function waitForBackend(targetClient = client, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (!targetClient.connected && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!targetClient.connected) {
    throw new Error(targetClient === pcvrClient
      ? 'PCVR host is not installed or did not connect'
      : 'desktop backend did not connect');
  }
}

async function waitForFoveatedConnected(timeoutSeconds) {
  const deadline = Date.now() + timeoutSeconds * 1000;
  while (Date.now() < deadline) {
    const status = await pcvrClient.rpc('FoveatedStatus');
    if (status.clientConnected && status.sessionStatus === 'CONNECTED') return status;
    if (status.state === 'error') {
      throw new Error(`foveated host entered error state: ${status.detail || 'unknown error'}`);
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`headset did not reach CONNECTED within ${timeoutSeconds}s`);
}

function runStackOperation(operation) {
  const run = stackOperationTail.catch(() => null).then(operation);
  stackOperationTail = run;
  return run;
}

async function dispatchControl(method, params = {}) {
  // Every method this dispatches (PcvrStatus/Start/Stop/.../GamesLaunch) lives on the PCVR
  // host's pipe, so it is the one whose connection actually gates readiness here.
  await waitForBackend(pcvrClient);
  const rpc = (name, rpcParams) => routeClientFor(name).rpc(name, rpcParams);
  const hostParams = params && params.hostParams ? params.hostParams : null;

  switch (method) {
    case 'PcvrStatus':
      return {
        foveated: await rpc('FoveatedStatus'),
        services: supervisor ? supervisor.status() : {},
      };
    case 'PcvrStart':
      return runStackOperation(() => supervisor.startStack(rpc, hostParams));
    case 'PcvrStop':
      return runStackOperation(() => supervisor.stopStack(rpc));
    case 'PcvrRestart':
      return runStackOperation(async () => {
        const stopped = await supervisor.stopStack(rpc);
        if (!stopped.ok) return stopped;
        return supervisor.startStack(rpc, hostParams);
      });
    case 'PcvrLaunch': {
      const gameId = params.gameId || 'steam:546560';
      return runStackOperation(async () => {
        await waitForFoveatedConnected(Math.min(Math.max(params.connectTimeoutSeconds || 120, 1), 600));
        const launched = await rpc('GamesLaunch', { id: gameId });
        if (!launched) throw new Error(`GamesLaunch refused or failed for ${gameId}`);
        return { ok: true, gameId };
      });
    }
    case 'PcvrRestartLaunch': {
      const gameId = params.gameId || 'steam:546560';
      const timeout = Math.min(Math.max(params.connectTimeoutSeconds || 120, 1), 600);
      return runStackOperation(async () => {
        const stopped = await supervisor.stopStack(rpc);
        if (!stopped.ok) return stopped;
        const started = await supervisor.startStack(rpc, hostParams);
        if (!started.ok) return started;
        const status = await waitForFoveatedConnected(timeout);
        const launched = await rpc('GamesLaunch', { id: gameId });
        if (!launched) throw new Error(`GamesLaunch refused or failed for ${gameId}`);
        return { ok: true, steps: started.steps, status, gameId };
      });
    }
    default:
      throw new Error(`unknown companion control method: ${method}`);
  }
}

// ---- IPC bridge: renderer -> backend RPC ----
ipcMain.handle('rpc', async (_e, method, params) => {
  const result = await routeClientFor(method).rpc(method, params);
  if (method === 'FoveatedStatus') {
    lastFoveatedStatus = result;
    syncPairingWindow(result);
  }
  return result;
});
// Whether the closed-source PCVR host is installed and its pipe is up right now — the
// renderer's real capability check, replacing a typeof-function probe that would always
// pass once preload.js unconditionally defines the Foveated*/Games* wrappers.
ipcMain.handle('pcvr-available', () => pcvrClient.connected);

// ---- On-demand PCVR bundle download (see pcvr-installer.js) ----
ipcMain.handle('pcvr-check-download', async () => {
  try {
    return await pcvrInstaller.checkAvailability();
  } catch (e) {
    return { available: false, reason: 'error', message: e.message };
  }
});

ipcMain.handle('pcvr-download-install', async (event) => {
  const sendProgress = (progress) => {
    if (!event.sender.isDestroyed()) event.sender.send('pcvr-download-progress', progress);
  };
  const result = await pcvrInstaller.downloadAndInstall(sendProgress);
  // Both paths were resolved once at startup against an install that did not exist yet;
  // push the now-discoverable paths into the running Supervisor and (re)spawn the host
  // instead of requiring an app restart to notice its own download.
  if (supervisor) supervisor.refreshPaths(resolvePcvrHostExe() || resolveBackendExe(), resolveBridgeRoot());
  startPcvrHost();
  return result;
});
/**
 * Native file picker for "Add a game". This is why the headset needs no filesystem access at all:
 * the user chooses the executable here, in a dialog, and only the resulting path is sent to the
 * backend. Returns null when the dialog is cancelled.
 */
ipcMain.handle('pick-executable', async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: 'Choose a game executable',
    properties: ['openFile', 'dontAddToRecent'],
    filters: [
      { name: 'Programs', extensions: ['exe'] },
      { name: 'All files', extensions: ['*'] },
    ],
  });
  if (result.canceled || result.filePaths.length === 0) return null;
  return result.filePaths[0];
});

/* Art is returned as a data: URL rather than a file:// path because the renderer's CSP allows
   `img-src 'self' data:` and nothing else. Widening it to `file:` to reach Steam's cache would be a
   real loosening for a cosmetic gain; base64 of a 30-40 KB jpg is cheap by comparison.

   The path is validated against Steam's art cache first, so this handler cannot be used as a
   general file reader even though the renderer is our own code. */
const artCache = new Map();

function steamArtRoot() {
  // Mirrors GameLibrary.SteamArtCacheRoot. Read from the registry would be better, but the renderer
  // only ever passes back paths the backend produced, so this is a bound, not a lookup.
  return ['C:\\Program Files (x86)\\Steam', 'C:\\Program Files\\Steam']
    .map((r) => path.join(r, 'appcache', 'librarycache'))
    .find((p) => fs.existsSync(p)) || null;
}

ipcMain.handle('game-art', async (_e, artPath) => {
  if (typeof artPath !== 'string' || artPath.length === 0) return null;
  if (artCache.has(artPath)) return artCache.get(artPath);

  const root = steamArtRoot();
  if (!root) return null;
  const full = path.resolve(artPath);
  if (!full.toLowerCase().startsWith(path.resolve(root).toLowerCase() + path.sep)) {
    console.warn('[main] refusing art outside the Steam cache:', full);
    return null;
  }
  const ext = path.extname(full).toLowerCase();
  const mime = ext === '.png' ? 'image/png' : ext === '.jpg' || ext === '.jpeg' ? 'image/jpeg' : null;
  if (!mime) return null;

  try {
    const url = `data:${mime};base64,${(await fs.promises.readFile(full)).toString('base64')}`;
    artCache.set(artPath, url);
    return url;
  } catch (e) {
    console.warn('[main] could not read art', full, e.message);
    return null;
  }
});

// ---- PCVR service supervision (replaces the Longwave-Broker/Sidecar tasks) ----
ipcMain.handle('services-status', () => (supervisor ? supervisor.status() : {}));
ipcMain.handle('services-start', (_e, name) =>
  runStackOperation(() => supervisor.startChecked(name)));
ipcMain.handle('services-stop', (_e, name) =>
  runStackOperation(() => supervisor.stop(name)));
ipcMain.handle('services-start-stack', (_e, params) =>
  runStackOperation(() => supervisor.startStack((m, p) => routeClientFor(m).rpc(m, p), params)));
ipcMain.handle('services-stop-stack', (_e, options) =>
  runStackOperation(() => supervisor.stopStack((m, p) => routeClientFor(m).rpc(m, p), options)));
ipcMain.handle('pcvr-desktop-quad', (_e, enabled) => supervisor.setDesktopQuad(enabled));
ipcMain.handle('confirm-pcvr-stop', () =>
  confirmRunningGameShutdown('Stop PCVR?', 'Stop PCVR'));
ipcMain.handle('open-notices-window', () => { createNoticesWindow(); });
ipcMain.handle('notices-read', () => fs.promises.readFile(noticesPath(), 'utf8'));
ipcMain.handle('notices-open-external', (event, url) => {
  // Only from the notices window, and only for the two schemes a licence file has any
  // business containing. Anything else is a bug in the notices, not a link to follow.
  if (!noticesWindow || noticesWindow.isDestroyed()
      || event.sender !== noticesWindow.webContents) return false;
  if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) return false;
  shell.openExternal(url);
  return true;
});
ipcMain.handle('open-pairing-window', () => {
  syncPairingWindow(lastFoveatedStatus, true);
  return pairingKey !== null;
});
ipcMain.handle('pairing-toggle-reveal', (event) => {
  if (!pairingWindow || pairingWindow.isDestroyed()
      || event.sender !== pairingWindow.webContents
      || pairingKey === null) return false;
  pairingRevealed = !pairingRevealed;
  sendPairingState();
  return pairingRevealed;
});

ipcMain.handle('get-connection', () => client.connected);
ipcMain.handle('gen-passphrase', () => randomToken(8));
ipcMain.handle('gen-ssid', () => `Longwave-${randomToken(4)}`);

// Tailscale helpers for the Foveated LAN/tailnet switch + DERP watchdog.
ipcMain.handle('tailscale-status', () => tailscaleStatus());
ipcMain.handle('tailscale-path', (_e, ip) => checkPath(ip));

if (gotSingleInstanceLock) app.on('second-instance', focusMainWindow);

if (gotSingleInstanceLock) app.whenReady().then(() => {
  startBackend();
  startPcvrHost();
  supervisor = new Supervisor({
    appRoot: path.join(__dirname, '..'),
    // The CloudXR runtime manifest is staged next to the PCVR host, not the public backend
    // (provision-pc.ps1's own staging target since the host split) — falling back to the
    // backend path only covers a pre-split leftover layout.
    backendExe: resolvePcvrHostExe() || resolveBackendExe(),
    bridgeRoot: resolveBridgeRoot(),
  });
  supervisor.on('log', (line) => console.log('[services]', line));
  supervisor.on('changed', (status) => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send('services', status);
  });
  client.start();
  pcvrClient.start();
  controlServer = new ControlServer(
    dispatchControl,
    (line) => console.log('[control]', line),
  );
  controlServer.start();
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  requestQuit();
});

app.on('before-quit', (event) => {
  if (allowQuit) return;
  event.preventDefault();
  requestQuit();
});

async function requestQuit() {
  if (allowQuit || quitInProgress) return;
  quitInProgress = true;

  if (!await confirmRunningGameShutdown('Quit Longwave?', 'Quit and stop PCVR')) {
    quitInProgress = false;
    return;
  }

  await shutdownPcvr();
  allowQuit = true;
  app.quit();
}

async function confirmRunningGameShutdown(title, destructiveLabel) {
  let status = lastFoveatedStatus;
  if (pcvrClient.connected) {
    try {
      status = await withTimeout(pcvrClient.rpc('FoveatedStatus'), 3000, 'FoveatedStatus');
    } catch { /* use the latest pushed snapshot */ }
  }
  if (!status || !status.gameRunning) return true;

  const options = {
    type: 'warning',
    title,
    message: 'A PCVR game is still running.',
    detail: 'Stopping PCVR will disconnect Vision Pro and stop the PCVR services. '
      + 'The game may also close or report that its OpenXR headset was disconnected.',
    buttons: ['Keep PCVR running', destructiveLabel],
    defaultId: 0,
    cancelId: 0,
    noLink: true,
  };
  const owner = mainWindow && !mainWindow.isDestroyed() ? mainWindow : null;
  const result = owner
    ? await dialog.showMessageBox(owner, options)
    : await dialog.showMessageBox(options);
  return result.response === 1;
}

async function shutdownPcvr() {
  // Stop in the same reverse order as the in-app button and wait for it to finish. Electron's
  // old before-quit hook could not await, so the process often disappeared while cleanup was
  // still in flight.
  if (supervisor) {
    try {
      const shutdownRpc = (method, params) =>
        withTimeout(routeClientFor(method).rpc(method, params), 5000, `${method} during shutdown`);
      const stopped = await runStackOperation(() => supervisor.stopStack(shutdownRpc));
      if (!stopped.ok) console.error('[main]', stopped.detail);
    } catch (e) {
      console.error('[main] PCVR shutdown failed:', e.message);
    }
    supervisor.shutdown();
  } else if (pcvrClient.connected) {
    try { await pcvrClient.rpc('FoveatedStop'); } catch { /* host teardown below is the fallback */ }
  }

  client.stop();
  pcvrClient.stop();
  if (controlServer) {
    await controlServer.stop();
    controlServer = null;
  }

  // Leave a service-hosted process running; only tear down children this app owns.
  await Promise.all([backendProc, pcvrHostProc].map((proc) => {
    if (!proc || proc.exitCode !== null) return null;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        try { proc.kill(); } catch { /* already gone */ }
        resolve();
      }, 3000);
      proc.once('exit', () => {
        clearTimeout(timer);
        resolve();
      });
      execFile('taskkill', ['/PID', String(proc.pid), '/T', '/F'], () => {
        clearTimeout(timer);
        resolve();
      });
    });
  }));
}
