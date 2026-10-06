'use strict';
const { app, BrowserWindow, ipcMain, dialog, shell, Notification, protocol, Tray, Menu, nativeTheme } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { spawn, execFile } = require('child_process');
const { HotspotClient, PCVR_PIPE_PATH } = require('./pipe-client');
const { tailscaleStatus, checkPath } = require('./tailscale');
const { Supervisor } = require('./supervisor');
const { ControlServer } = require('./control-server');
const pcvrInstaller = require('./pcvr-installer');
const updater = require('./updater');
const gameLauncher = require('./game-launcher');

// Custom scheme the downloaded PCVR module's own pages load from (pcvr-module://ui/pcvr.html
// etc.), so the <webview> hosting them never needs a bare file:// URL into a user-writable
// download directory. Serves out of pcvrInstaller.INSTALL_ROOT/ui/ — the verified, extracted
// module's web assets — nothing else. Registered as 'standard'+'secure' before app ready,
// which is required for a scheme to behave enough like https: for fetch/CSP to work inside
// it. The <webview>'s own `preload` attribute is set separately (see renderer.js's
// ensurePcvrModuleLoaded()) to a real file: URL, since preload scripts are loaded via
// Node's require and must be file:.
protocol.registerSchemesAsPrivileged([{
  scheme: 'pcvr-module',
  privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true },
}]);

const PCVR_MODULE_MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml',
};

const PRELOAD_FILE_URL = require('url').pathToFileURL(path.join(__dirname, 'preload.js')).href;
// The renderer is sandboxed (no __dirname of its own — and neither does a sandboxed preload,
// see preload.js's comment), so it asks the main process for this rather than computing it.
ipcMain.handle('get-preload-url', () => PRELOAD_FILE_URL);

/**
 * Where the PCVR/Games pages live. Same three-way shape as resolvePcvrHostExe(): the
 * downloaded bundle first, then a packaged build's staged resources, then a dev checkout.
 *
 * The dev candidate is the one that was missing. When the PCVR UI moved into the closed-source
 * module (2026-08-18) this root became bundle-only, which is right for a real install and wrong
 * for every source checkout: the host exe still resolves from the dev tree, so its pipe
 * connects, the renderer decides PCVR is available and loads pcvr-module://ui/pcvr.html — and
 * gets a bare "not found", because a dev host never downloads a bundle. Every other resolver in
 * this file already had a dev fallback; this one did not, which is why it only broke here.
 *
 * Resolved PER REQUEST rather than once at registration. The bundle can arrive at any point
 * during a run (that is what the PCVR tab's download button does), and a root captured at
 * startup would have been resolved before it existed — the same staleness bug that
 * Supervisor.refreshPaths() exists to work around for the binaries. Two existsSync calls per
 * request is nothing next to reading the file we are about to serve anyway.
 */
function resolvePcvrUiRoot() {
  const candidates = [
    path.join(pcvrInstaller.INSTALL_ROOT, 'ui'),
    ...(app.isPackaged
      ? [path.join(process.resourcesPath, 'pcvr-host', 'ui')]
      : [path.join(__dirname, '..', '..', '..', 'Longwave-PCVR-Host', 'ui')]),
  ];
  return candidates.find((p) => fs.existsSync(p)) || null;
}

function registerPcvrModuleProtocol() {
  protocol.handle('pcvr-module', (request) => {
    const root = resolvePcvrUiRoot();
    if (!root) {
      // Distinguished from a missing file on purpose: "no UI installed at all" is a different
      // situation from "that page does not exist", and the first one used to render as the
      // second, which is a long way from the actual cause.
      return new Response('the PCVR module UI is not installed', { status: 404 });
    }
    const url = new URL(request.url);
    const rel = decodeURIComponent(url.pathname || '/pcvr.html').replace(/^\/+/, '') || 'pcvr.html';
    // Resolve and pin inside root — url.pathname is already URL-decoded and path-normalized
    // by the WHATWG URL parser (collapses ".." itself), but this is the one boundary where a
    // downloaded zip's own contents reach the filesystem, so check anyway rather than trust it.
    const resolved = path.resolve(root, rel);
    if (resolved !== root && !resolved.startsWith(root + path.sep)) {
      return new Response('forbidden', { status: 403 });
    }
    let data;
    try {
      data = fs.readFileSync(resolved);
    } catch {
      return new Response('not found', { status: 404 });
    }
    const type = PCVR_MODULE_MIME[path.extname(resolved).toLowerCase()] || 'application/octet-stream';
    return new Response(data, { headers: { 'content-type': type } });
  });
}

let mainWindow = null;
let pairingWindow = null;
let noticesWindow = null;
let launcherWindow = null;
let launchInFlight = false;
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
let tray = null;
let stackOperationTail = Promise.resolve();
// The public backend (hotspot, native mac streaming) — always present.
const client = new HotspotClient();
// The closed-source CloudXR/Foveated host — a separate process with its own pipe, present
// only when the user has installed it. Its own connect/reconnect loop already degrades to
// "never connects" when the exe or the pipe is missing, so no feature-detection is needed
// beyond checking pcvrClient.connected.
const pcvrClient = new HotspotClient(PCVR_PIPE_PATH);
// Foveated*/Games* methods live on the PCVR host's pipe; everything else (hotspot, native
// screen streaming, the Library* game library, Ping) is the public backend. Method names are unique across both pipes
// by construction, so a prefix check is unambiguous.
function routeClientFor(method) {
  return method.startsWith('Foveated') || method.startsWith('Games') ? pcvrClient : client;
}
// How many leading argv entries are the program itself: the exe when packaged, `electron .` in a
// checkout. Everything after is ours to read — gameRequestFromArgv skips switches regardless.
const ARGV_SKIP = process.defaultApp ? 2 : 1;
// A game on our own command line (`--launch <path>`, `--launch-title <id>`, or a path dropped on
// the exe or its shortcut). Handed to an already-running instance through the lock's
// additionalData, so it arrives intact even though Chromium rewrites the argv the
// second-instance event reports.
const commandLineGame = gameLauncher.gameRequestFromArgv(process.argv, { skip: ARGV_SKIP });
const gotSingleInstanceLock = app.requestSingleInstanceLock({ launch: commandLineGame });

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
 * Where the host-built PCVR binaries live: the broker, the OpenXR controller-bridge layer DLL,
 * and any optional services the bundle declares (supervisor.js, services.json). The on-demand download (pcvr-installer.js) is the path a real
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
/* Where this process's own logs go. A dev checkout keeps them beside the tree (logs\ under
   CompanionWindows\, as deploy-windows-companion.sh and the docs expect). A packaged install
   cannot: it lives in Program Files, which the unelevated app may not write, so every log
   failed to open and the backend's output went nowhere — on exactly the machines where nobody
   can attach a debugger. userData is per-user and always writable. */
function logDirectory() {
  return app.isPackaged
    ? path.join(app.getPath('userData'), 'logs')
    : path.join(__dirname, '..', '..', 'logs');
}

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
    const logPath = path.join(logDirectory(), 'backend.log');
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    backendLog = fs.createWriteStream(logPath, { flags: 'w' });
    backendLog.on('error', (e) => {
      console.warn('[main] backend log unavailable:', e.message);
      backendLog = null;
    });
  } catch (e) {
    console.warn('[main] backend log unavailable:', e.message);
  }
  // LONGWAVE_STATE_DIR: the game library keeps its state beside this app's own (userData).
  backendProc = spawn(exe, [], {
    windowsHide: true,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, LONGWAVE_STATE_DIR: app.getPath('userData') },
  });
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
    const logPath = path.join(logDirectory(), 'pcvr-host.log');
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

function createWindow({ show = true } = {}) {
  mainWindow = new BrowserWindow({
    show,
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
      // Only the main window hosts the PCVR/Games <webview>s that load the downloaded module.
      webviewTag: true,
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
  // Closing the window keeps the stack running in the tray; Quit lives in the tray menu.
  mainWindow.on('close', (event) => {
    if (allowQuit) return;
    event.preventDefault();
    mainWindow.hide();
    showTrayHintOnce();
  });
}

// The app icon's wave without its tile: white on a dark taskbar, near-black on a light one.
// Windows can theme the taskbar separately from apps, hence the system-UI flag.
function trayImagePath() {
  const dark = process.platform === 'win32'
    ? nativeTheme.shouldUseDarkColorsForSystemIntegratedUI
    : nativeTheme.shouldUseDarkColors;
  return path.join(__dirname, 'assets', dark ? 'tray-dark.png' : 'tray-light.png');
}

function createTray() {
  tray = new Tray(trayImagePath());
  tray.setToolTip('Longwave Companion');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'Open Longwave Companion', click: focusMainWindow },
    { label: 'Launch game…', click: openLauncherWindow },
    { type: 'separator' },
    { label: 'Quit Longwave', click: () => requestQuit() },
  ]));
  tray.on('click', focusMainWindow);
  nativeTheme.on('updated', () => {
    if (tray && !tray.isDestroyed()) tray.setImage(trayImagePath());
  });
}

// Said once, the first time closing the window doesn't quit, so the app isn't mistaken for gone.
function showTrayHintOnce() {
  const flag = path.join(app.getPath('userData'), 'tray-hint-shown');
  if (fs.existsSync(flag)) return;
  try { fs.writeFileSync(flag, ''); } catch { /* shown again next time, harmless */ }
  const hint = new Notification({
    title: 'Longwave is still running',
    body: 'It keeps serving your headset from the tray. Right-click the wave icon to quit.',
  });
  hint.on('click', focusMainWindow);
  hint.show();
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

async function assertPcvrStoppedForDriverInstall(driverName = 'ViGEmBus') {
  const servicesRunning = supervisor
    && Object.values(supervisor.status()).some((service) => service.running || service.healthy);
  if (servicesRunning) {
    throw new Error(`Stop PCVR before installing ${driverName}.`);
  }
  if (!pcvrClient.connected) return;

  const status = await pcvrClient.rpc('FoveatedStatus');
  lastFoveatedStatus = status;
  syncPairingWindow(status);
  if (status && (status.state === 'on' || status.state === 'starting')) {
    throw new Error(`Stop PCVR before installing ${driverName}.`);
  }
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
        await launchTitleInVr(gameId);
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
        await launchTitleInVr(gameId);
        return { ok: true, steps: started.steps, status, gameId };
      });
    }
    default:
      throw new Error(`unknown companion control method: ${method}`);
  }
}

// ---- Game library launching: the Games tab, Launch game…, shortcuts (NATIVE_V3 §7.6) ----
//
// The library is the public backend's (Library* RPCs; CompanionWindows/backend/Games). It resolves
// a title to an executable, arguments, working folder and Steam identity, and starts Steam first
// when needed. This process decides where the title runs and starts it:
//   * flat titles always start on the desktop, here;
//   * VR / both titles go to the PCVR host (GamesLaunchResolved: the CloudXR-specific start) while a
//     headset is connected to the PCVR session; a session still starting, or one no headset has
//     joined yet, is waited for (bounded), then desktop;
//   * a browsed .exe (or .lnk to one) is matched to the library by path. A custom title's own
//     exe, or the exe a Steam title's launch entry would start, launches that title. Any other
//     file in a Steam game's folder runs exactly as picked, with that game's Steam identity (so
//     its DRM does not relaunch it through Steam). A file the library does not know is offered
//     "Add to library" in the picker, or started as is from the command line;
//   * a .url opens the library title its steam:// id names, else its scheme's handler; a .lnk to
//     something other than a program is opened by the shell.
// Nothing here elevates: this process is asInvoker, spawn cannot raise a UAC prompt, and a game
// that demands administrator rights fails with a message instead. Desktop games are children of
// this process (not tree-killed: nothing kills this process's tree), so they outlive it; the backend never starts them because it is
// tree-killed on quit.

const userDataDir = () => app.getPath('userData');
const VR_WAIT_SECONDS = 60;
const RESOLVE_TIMEOUT_MS = 45000; // Steam may need starting first (up to ~32 s)

/** An RPC error's message without the "exception: " / "methodNotFound: " code prefix. */
function rpcMessage(e) {
  return String(e && e.message ? e.message : e).replace(/^[a-zA-Z]+: /, '');
}

function sendLauncher(channel, payload) {
  if (launcherWindow && !launcherWindow.isDestroyed()) launcherWindow.webContents.send(channel, payload);
}

function sendLauncherMode() {
  sendLauncher('launcher-mode', { pcvrOn: pcvrSessionState() });
}

/** 'on', 'starting' or 'off', from the PCVR host's last status. */
function pcvrSessionState() {
  if (!pcvrClient.connected || !lastFoveatedStatus) return 'off';
  return lastFoveatedStatus.state === 'on' || lastFoveatedStatus.state === 'starting'
    ? lastFoveatedStatus.state : 'off';
}

/** Up to 10 s for the pipes a launch may need: the public backend, and the PCVR host if installed. */
async function waitForLaunchPipes() {
  const waits = [waitForBackend(client, 10000).catch(() => null)];
  if (process.env.LONGWAVE_NO_SPAWN === '1' || resolvePcvrHostExe()) {
    waits.push(waitForBackend(pcvrClient, 10000).catch(() => null));
  }
  await Promise.all(waits);
}

async function refreshFoveatedStatus() {
  if (!pcvrClient.connected) return null;
  try {
    lastFoveatedStatus = await withTimeout(pcvrClient.rpc('FoveatedStatus'), 3000, 'FoveatedStatus');
  } catch { /* the last pushed snapshot */ }
  return lastFoveatedStatus;
}

async function libraryRpc(method, params, timeoutMs) {
  if (!client.connected) throw new Error('The Companion\'s backend is not running, so the game library is unavailable.');
  try {
    return await client.rpc(method, params, timeoutMs);
  } catch (e) {
    throw new Error(rpcMessage(e));
  }
}

function libraryList() {
  return client.connected ? libraryRpc('LibraryList', null).catch(() => []) : Promise.resolve([]);
}

/** Resolve a title (Steam started first when needed) and start it in VR through the PCVR host. */
async function launchTitleInVr(id) {
  await waitForBackend(client, 10000);
  const plan = await libraryRpc('LibraryResolveLaunch', { id, vr: true }, RESOLVE_TIMEOUT_MS);
  const ok = await pcvrClient.rpc('GamesLaunchResolved', plan);
  if (!ok) {
    throw new Error(`The PCVR host could not start ${plan.name}. It refuses a second PCVR game while `
      + 'one is running; otherwise pcvr-host.log in the Companion\'s logs says why.');
  }
  return plan;
}

function spawnDetached(exe, args, cwd, env) {
  return new Promise((resolve, reject) => {
    let child;
    try {
      // Verbatim, so a shortcut's or Steam's argument string reaches the game exactly as written;
      // argv0 carries its own quotes for the same reason.
      // Not `detached`: on Windows that is DETACHED_PROCESS, which leaves a console program with
      // no console at all (found on gaming-pc: a console game's child tools ran and printed nothing).
      // Without it a console game gets its own window, as from Explorer, and Windows never ties
      // a child's lifetime to its parent's, so the game still outlives the Companion.
      child = spawn(exe, args ? [args] : [], {
        cwd, env, stdio: 'ignore', windowsHide: false, windowsVerbatimArguments: true, argv0: `"${exe}"`,
      });
    } catch (e) {
      reject(e);
      return;
    }
    child.once('error', reject);
    child.once('spawn', () => { child.unref(); resolve(child.pid); });
  });
}

function spawnErrorMessage(e, name) {
  if (e && e.code === 'EACCES') {
    return `Windows would not start ${name}. It may ask for administrator rights, and Longwave `
      + 'never starts games as administrator. Start it yourself if it needs them.';
  }
  if (e && e.code === 'ENOENT') return `${name} could not be found.`;
  return `${name} did not start: ${e && e.message ? e.message : e}`;
}

async function startDesktop(exe, args, cwd, steamAppId, name) {
  try {
    await spawnDetached(exe, args, cwd, gameLauncher.childEnvironment(process.env, steamAppId));
  } catch (e) {
    throw new Error(spawnErrorMessage(e, name));
  }
}

/**
 * Starts a library title where it belongs. Returns { name, where } for the notification. When the
 * PCVR session is still starting this waits for the headset, then falls back to the desktop.
 */
async function launchLibraryTitle(id) {
  const title = await libraryRpc('LibraryGet', { id });
  if (!title) throw new Error('That game is no longer in the library.');
  await refreshFoveatedStatus();
  let mode = gameLauncher.launchModeFor(pcvrClient.connected, lastFoveatedStatus, title.kind);
  let fellBack = false;
  if (mode === 'wait') {
    try {
      await waitForFoveatedConnected(VR_WAIT_SECONDS);
      mode = 'vr';
    } catch {
      mode = 'flat';
      fellBack = true;
    }
  }
  if (mode === 'vr') {
    await launchTitleInVr(id);
  } else {
    const plan = await libraryRpc('LibraryResolveLaunch', { id, vr: false }, RESOLVE_TIMEOUT_MS);
    await startDesktop(plan.executable, plan.arguments, plan.workingDirectory, plan.steamAppId, plan.name);
  }
  libraryRpc('LibraryMarkPlayed', { id }).catch(() => null);
  return {
    name: title.name,
    where: mode === 'vr' ? 'in VR through PCVR' : 'on the desktop',
    fellBack,
  };
}

/**
 * What a file stands for: a library title (matched by path, or a steam:// .url), or a plain
 * start. `addToLibrary(info)` is asked, in the picker only, about a program that is not in the
 * library; it returns a kind ('flat' / 'vr'), 'launch' or null (cancel).
 */
async function resolveFile(filePath, { addToLibrary = null } = {}) {
  const kind = gameLauncher.fileKind(filePath);
  const name = gameLauncher.displayName(filePath);
  if (!kind) throw new Error('Choose a program (.exe), a shortcut (.lnk) or an internet shortcut (.url).');
  if (!fs.existsSync(filePath)) throw new Error(`${filePath} no longer exists.`);

  const forExe = async (exe, args, cwd) => {
    const plain = { kind: 'exe', name, exe, args: args || '', cwd: cwd || path.dirname(exe) };
    const match = client.connected ? await libraryRpc('LibraryMatchPath', { path: exe }).catch(() => null) : null;
    if (match && match.exact) return { kind: 'title', id: match.title.id, name: match.title.name };
    if (match) {
      // A Steam game's folder. Its launch entry's own exe is the title; anything else runs as
      // picked, as that Steam app.
      const title = match.title;
      await refreshFoveatedStatus();
      const mode = gameLauncher.launchModeFor(pcvrClient.connected, lastFoveatedStatus, title.kind);
      const usesVrEntry = mode !== 'flat' || title.kind === 'vr';
      if (usesVrEntry ? match.vrEntry : match.desktopEntry) {
        return { kind: 'title', id: title.id, name: title.name };
      }
      if (addToLibrary) {
        const answer = await addToLibrary({ name, exe, linkedTitle: title });
        if (answer === null) return { kind: 'cancel' };
        if (answer === 'flat' || answer === 'vr') {
          const added = await libraryRpc('LibraryAddCustom', {
            path: exe, name, arguments: args || null, kind: answer, linkedSteamAppId: title.steamAppId,
          });
          return { kind: 'title', id: added.id, name: added.name };
        }
      }
      return { ...plain, steamAppId: title.steamAppId };
    }
    if (addToLibrary) {
      const answer = await addToLibrary({ name, exe });
      if (answer === null) return { kind: 'cancel' };
      if (answer === 'flat' || answer === 'vr') {
        const added = await libraryRpc('LibraryAddCustom', { path: exe, arguments: args || null, kind: answer });
        return { kind: 'title', id: added.id, name: added.name };
      }
    }
    return plain;
  };

  if (kind === 'exe') return forExe(filePath);
  if (kind === 'lnk') {
    let link = null;
    try { link = shell.readShortcutLink(filePath); } catch { /* advertised/odd shortcuts */ }
    if (link && link.target && gameLauncher.fileKind(link.target) === 'exe' && fs.existsSync(link.target)) {
      return forExe(link.target, link.args, link.cwd);
    }
    return { kind: 'open', name, path: filePath };
  }
  const url = gameLauncher.parseInternetShortcut(await fs.promises.readFile(filePath, 'utf8'));
  if (!url) throw new Error(`${path.basename(filePath)} has no address in it.`);
  const appId = gameLauncher.steamAppIdFromUrl(url);
  if (appId && client.connected) {
    const title = await libraryRpc('LibraryGet', { id: `steam:${appId}` }).catch(() => null);
    if (title) return { kind: 'title', id: title.id, name: title.name };
  }
  if (!gameLauncher.urlAllowed(url)) {
    throw new Error('That shortcut points at a file rather than a game launcher, so Longwave will not open it.');
  }
  return { kind: 'url', name, url };
}

async function performResolved(r) {
  switch (r.kind) {
    case 'title': return launchLibraryTitle(r.id);
    case 'exe':
      if (r.steamAppId && !await libraryRpc('LibraryEnsureSteam', null, RESOLVE_TIMEOUT_MS)) {
        throw new Error(`${r.name} is part of a Steam game and Steam could not be started. Start Steam, then try again.`);
      }
      await startDesktop(r.exe, r.args, r.cwd, r.steamAppId || null, r.name);
      return { name: r.name, where: 'on the desktop' };
    case 'url':
      await shell.openExternal(r.url);
      return { name: r.name, where: 'through its launcher' };
    case 'open': {
      const error = await shell.openPath(r.path);
      if (error) throw new Error(`${r.name} did not open: ${error}`);
      return { name: r.name, where: 'through its shortcut' };
    }
    default:
      throw new Error(`unknown launch ${r.kind}`);
  }
}

async function confirmLaunch(owner) {
  if (gameLauncher.consentRemembered(userDataDir())) return true;
  const options = gameLauncher.consentMessageOptions();
  const result = owner ? await dialog.showMessageBox(owner, options) : await dialog.showMessageBox(options);
  try {
    return gameLauncher.applyConsentAnswer(userDataDir(), result);
  } catch (e) {
    console.warn('[launcher] could not save the launch choice:', e.message);
    return result.response === 0;
  }
}

function showLaunchError(owner, message) {
  const options = { type: 'error', title: 'Launch game', message: 'The game did not start.', detail: message, noLink: true };
  return owner ? dialog.showMessageBox(owner, options) : dialog.showMessageBox(options);
}

async function askAddToLibrary(owner, { name, linkedTitle = null }) {
  const options = {
    type: 'question',
    title: 'Add to library',
    message: `Add ${name} to your game library?`,
    detail: (linkedTitle
      ? `It is part of ${linkedTitle.name}, so it will run as that Steam game, exactly this file. `
      : '')
      + 'Games in the library keep their launch settings, appear in the Games tab and the '
      + 'tray, and can get a desktop shortcut. Choose how it is played.',
    buttons: ['Add as a desktop game', 'Add as a VR game', 'Launch without adding', 'Cancel'],
    defaultId: linkedTitle && linkedTitle.kind === 'vr' ? 1 : 0,
    cancelId: 3,
    noLink: true,
  };
  const { response } = owner ? await dialog.showMessageBox(owner, options) : await dialog.showMessageBox(options);
  return ['flat', 'vr', 'launch', null][response] ?? null;
}

/**
 * One launch, start to finish. `resolve()` turns the request into something startable (or throws a
 * user-facing Error). Consent comes first, so declining starts nothing at all. Returns whether
 * the game started.
 */
async function runLaunch(resolve, { owner = null, recent = null } = {}) {
  if (launchInFlight) {
    // Said, not swallowed: a shortcut launch has no window, so silence reads as a broken shortcut.
    console.log('[launcher] launch refused: another one is still starting');
    new Notification({
      title: 'Another game is still starting',
      body: 'Longwave starts one game at a time. Try again once the first one has started.',
    }).show();
    return false;
  }
  launchInFlight = true;
  try {
    if (!await confirmLaunch(owner)) return false;
    let started;
    let resolved;
    try {
      resolved = await resolve();
      if (resolved.kind === 'cancel') return false;
      started = await performResolved(resolved);
    } catch (e) {
      console.warn('[launcher] launch failed:', e.message);
      await showLaunchError(owner, e.message);
      return false;
    }
    console.log(`[launcher] started ${resolved.kind} ${started.where}`);
    gameLauncher.addRecent(userDataDir(), resolved.kind === 'title'
      ? { kind: 'title', id: resolved.id, name: resolved.name }
      : (recent || { kind: 'file', path: resolved.path || resolved.exe, name: resolved.name }));
    new Notification({
      title: `Starting ${started.name}`,
      body: started.fellBack
        ? 'The headset did not connect in time, so it started on the desktop instead.'
        : `Launched ${started.where} by Longwave.`,
    }).show();
    return true;
  } finally {
    launchInFlight = false;
  }
}

/** The command-line path: the picker's Browse minus the picker (and minus "Add to library"),
 *  and no window comes forward. */
function launchFromCommandLine(request) {
  console.log('[launcher] command-line launch requested');
  if (request.titleId) {
    return runLaunch(async () => ({ kind: 'title', id: request.titleId, name: request.titleId }));
  }
  return runLaunch(() => resolveFile(request.path),
    { recent: { kind: 'file', path: request.path, name: gameLauncher.displayName(request.path) } });
}

function openLauncherWindow() {
  if (launcherWindow && !launcherWindow.isDestroyed()) {
    if (launcherWindow.isMinimized()) launcherWindow.restore();
    launcherWindow.show();
    launcherWindow.focus();
    return;
  }
  launcherWindow = new BrowserWindow({
    width: 480,
    height: 600,
    minWidth: 400,
    minHeight: 420,
    title: 'Launch game — Longwave',
    icon: path.join(__dirname, '..', 'buildResources', 'icon.ico'),
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#1B1A18' : '#F4F1EC',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'launcher-preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  launcherWindow.removeMenu();
  launcherWindow.loadFile(path.join(__dirname, 'renderer', 'launcher.html'));
  launcherWindow.on('closed', () => { launcherWindow = null; });
}

const fromLauncher = (event) => launcherWindow && !launcherWindow.isDestroyed()
  && event.sender === launcherWindow.webContents;
const fromMainWindow = (event) => mainWindow && !mainWindow.isDestroyed()
  && event.sender === mainWindow.webContents;

/** The library as the picker shows it: name, kind, profile — no paths. */
function pickerTitle(t) {
  return { id: t.id, name: t.name, kind: t.kind, optimised: Boolean(t.optimizedAvailable && t.optimized) };
}

function recentView(recent, byId) {
  const key = gameLauncher.recentKey(recent);
  if (recent.kind === 'title') {
    const title = byId.get(recent.id);
    return title ? { key, kind: 'title', name: title.name, detail: kindLabel(title.kind), canShortcut: true } : null;
  }
  if (!fs.existsSync(recent.path)) return null;
  return { key, kind: 'file', name: recent.name, detail: recent.path, canShortcut: true };
}

function kindLabel(kind) {
  return kind === 'vr' ? 'VR' : kind === 'both' ? 'VR and desktop' : 'Desktop';
}

ipcMain.handle('launcher-state', async (event) => {
  if (!fromLauncher(event)) return null;
  const titles = await libraryList();
  const byId = new Map(titles.map((t) => [t.id, t]));
  await refreshFoveatedStatus();
  return {
    pcvrOn: pcvrSessionState(),
    libraryAvailable: client.connected,
    askBeforeLaunch: !gameLauncher.consentRemembered(userDataDir()),
    titles: titles.map(pickerTitle),
    recents: gameLauncher.loadRecents(userDataDir()).map((r) => recentView(r, byId)).filter(Boolean),
  };
});

async function launchFromPicker(resolve, recent) {
  const started = await runLaunch(resolve, { owner: launcherWindow, recent });
  if (started && launcherWindow && !launcherWindow.isDestroyed()) launcherWindow.close();
  return started;
}

ipcMain.handle('launcher-launch-title', (event, id) => {
  if (!fromLauncher(event) || typeof id !== 'string') return false;
  return launchFromPicker(async () => ({ kind: 'title', id, name: id }));
});

ipcMain.handle('launcher-launch-recent', (event, key) => {
  if (!fromLauncher(event)) return false;
  const recent = gameLauncher.loadRecents(userDataDir()).find((r) => gameLauncher.recentKey(r) === key);
  if (!recent) return false;
  return launchFromPicker(async () => (recent.kind === 'file'
    ? resolveFile(recent.path, { addToLibrary: (info) => askAddToLibrary(launcherWindow, info) })
    : { kind: 'title', id: recent.id, name: recent.name }), recent);
});

async function browseForGame(owner, { title = 'Choose a game', withUrl = true } = {}) {
  const result = await dialog.showOpenDialog(owner, {
    title,
    properties: ['openFile', 'dontAddToRecent'],
    filters: [
      { name: 'Games and shortcuts', extensions: withUrl ? ['exe', 'lnk', 'url'] : ['exe', 'lnk'] },
      { name: 'All files', extensions: ['*'] },
    ],
  });
  return result.canceled || result.filePaths.length === 0 ? null : result.filePaths[0];
}

ipcMain.handle('launcher-browse', async (event) => {
  if (!fromLauncher(event)) return false;
  const filePath = await browseForGame(launcherWindow);
  if (!filePath) return false;
  return launchFromPicker(
    () => resolveFile(filePath, { addToLibrary: (info) => askAddToLibrary(launcherWindow, info) }),
    { kind: 'file', path: filePath, name: gameLauncher.displayName(filePath) });
});

ipcMain.handle('launcher-set-ask', (event, ask) => {
  if (!fromLauncher(event) && !fromMainWindow(event)) return null;
  gameLauncher.setConsentRemembered(userDataDir(), !ask);
  return !gameLauncher.consentRemembered(userDataDir());
});

/**
 * A desktop shortcut that starts a game through Longwave: the Companion exe with
 * `--launch-title <id>` (library titles) or `--launch "<path>"` (other files), the game's name
 * and icon. Returns the shortcut's path, or null.
 */
function writeGameShortcut({ name, request, icon, cwd }) {
  const linkPath = path.join(app.getPath('desktop'), gameLauncher.shortcutFileName(name));
  const launchArgs = gameLauncher.shortcutArguments(request);
  const ok = shell.writeShortcutLink(linkPath, 'create', {
    target: process.execPath,
    // A checkout runs as `electron <app dir>`, so the app directory goes first there.
    args: app.isPackaged ? launchArgs : `"${app.getAppPath()}" ${launchArgs}`,
    cwd: cwd || path.dirname(process.execPath),
    description: `Start ${name} through Longwave`,
    icon: icon && fs.existsSync(icon) ? icon : process.execPath,
    iconIndex: 0,
  });
  return ok ? linkPath : null;
}

async function shortcutForTitle(id) {
  const title = await libraryRpc('LibraryGet', { id });
  if (!title) return null;
  return writeGameShortcut({
    name: title.name,
    request: { titleId: title.id },
    icon: title.icon || title.executable || null,
    cwd: title.installDir || null,
  });
}

ipcMain.handle('launcher-create-shortcut', async (event, key) => {
  if (!fromLauncher(event)) return null;
  const recent = gameLauncher.loadRecents(userDataDir()).find((r) => gameLauncher.recentKey(r) === key);
  if (!recent) return null;
  if (recent.kind === 'title') return shortcutForTitle(recent.id);
  if (!fs.existsSync(recent.path)) return null;
  let icon = recent.path;
  if (gameLauncher.fileKind(recent.path) === 'lnk') {
    try {
      const link = shell.readShortcutLink(recent.path);
      icon = link.icon || link.target || null;
    } catch { icon = null; }
  } else if (gameLauncher.fileKind(recent.path) === 'url') {
    icon = null;
  }
  return writeGameShortcut({
    name: recent.name, request: { path: recent.path }, icon, cwd: path.dirname(recent.path),
  });
});

ipcMain.handle('launcher-close', (event) => {
  if (fromLauncher(event)) launcherWindow.close();
});

// The Games tab's own actions. Curation calls (LibraryList/SetExposed/…) go through the generic
// 'rpc' bridge; these three need the main process (dialogs, spawning, the desktop).
ipcMain.handle('library-launch', async (event, id) => {
  if (!fromMainWindow(event) || typeof id !== 'string') return false;
  return runLaunch(async () => ({ kind: 'title', id, name: id }), { owner: mainWindow });
});

ipcMain.handle('library-create-shortcut', async (event, id) => {
  if (!fromMainWindow(event) || typeof id !== 'string') return null;
  return shortcutForTitle(id);
});

/** "Add a game…": pick a program or shortcut, choose VR or desktop, add it. Returns the title. */
ipcMain.handle('library-add', async (event) => {
  if (!fromMainWindow(event)) return null;
  const filePath = await browseForGame(mainWindow, { title: 'Add a game to the library', withUrl: false });
  if (!filePath) return null;
  let exe = filePath;
  let args = null;
  if (gameLauncher.fileKind(filePath) === 'lnk') {
    const link = shell.readShortcutLink(filePath);
    if (!link.target || gameLauncher.fileKind(link.target) !== 'exe') {
      throw new Error('That shortcut does not point at a program.');
    }
    exe = link.target;
    args = link.args || null;
  }
  const match = await libraryRpc('LibraryMatchPath', { path: exe });
  // Already there: a custom title's exe, or the exe a Steam title's own entry starts.
  if (match && (match.exact || match.desktopEntry || match.vrEntry)) {
    rememberLibraryArt(match.title);
    return match.title;
  }
  // Any other file in a Steam game's folder becomes a custom entry linked to that game: it runs
  // exactly this file, with the game's Steam identity and art.
  const linked = match ? match.title : null;
  const options = {
    type: 'question',
    title: 'Add a game',
    message: `How is ${gameLauncher.displayName(filePath)} played?`,
    detail: linked ? `It is part of ${linked.name}, so it will run as that Steam game, exactly this file.` : undefined,
    buttons: ['On the desktop', 'In VR', 'Cancel'],
    defaultId: linked && linked.kind === 'vr' ? 1 : 0,
    cancelId: 2,
    noLink: true,
  };
  const { response } = await dialog.showMessageBox(mainWindow, options);
  if (response === 2) return null;
  const added = await libraryRpc('LibraryAddCustom', {
    path: exe,
    name: gameLauncher.displayName(filePath),
    arguments: args,
    kind: response === 1 ? 'vr' : 'flat',
    linkedSteamAppId: linked ? linked.steamAppId : null,
  });
  // The Games tab shows it straight away, before its next LibraryList: let its cover through.
  rememberLibraryArt(added);
  return added;
});

ipcMain.handle('library-ask-state', (event) => {
  if (!fromMainWindow(event)) return null;
  return !gameLauncher.consentRemembered(userDataDir());
});

// ---- IPC bridge: renderer -> backend RPC ----
ipcMain.handle('rpc', async (_e, method, params) => {
  const invoke = () => routeClientFor(method).rpc(method, params);
  const result = method === 'FoveatedStart' || method === 'FoveatedStop'
    ? await runStackOperation(invoke)
    : await invoke();
  if (method === 'FoveatedStatus') {
    lastFoveatedStatus = result;
    syncPairingWindow(result);
  }
  if (typeof method === 'string' && method.startsWith('Library')) rememberLibraryArt(result, method === 'LibraryList');
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
// ---- App self-update (notify-only — see updater.js) ----
//
// Nothing here runs on a timer. The renderer asks once when it loads and whenever the user
// opens the About/Updates area; a background poller would mean an update banner appearing
// mid-session, over a headset, which is the one moment nobody wants to read one.
ipcMain.handle('update-check', async (_e, options) => {
  try {
    return await updater.check(options || {});
  } catch (e) {
    return { available: false, reason: 'error', message: e.message };
  }
});

ipcMain.handle('update-download', async (event) => {
  const sendProgress = (progress) => {
    if (!event.sender.isDestroyed()) event.sender.send('update-download-progress', progress);
  };
  return updater.downloadAndVerify(sendProgress);
});

// Separate from the download on purpose: this one quits the app, so it happens only on a
// second, explicit click, after the download has been verified and the user has been told
// that continuing closes everything the app is supervising.
ipcMain.handle('update-install', async (_e, installerPath) => {
  if (supervisor) {
    // A running broker holds the CloudXR service and a game; letting NSIS replace files
    // underneath that is how you get a half-updated install and an orphaned session. No
    // options: `restarting` is the only one stopStack honours, and nothing is restarting here.
    await runStackOperation(() => supervisor.stopStack(
      (m, params) => routeClientFor(m).rpc(m, params))).catch(() => null);
  }
  updater.installAndQuit(installerPath);
  return { ok: true };
});

ipcMain.handle('update-open-page', async () => {
  const info = await updater.check().catch(() => null);
  return updater.openReleasePage(info);
});

// ---- PCVR bundle: version pairing and the installer's opt-in checkbox ----
//
// The bundle is paired to the app release it was built for (there is no version negotiation on
// the pipe between them), so an app update leaves a bundle that must not be started. The
// renderer prompts; `services-start-stack` below is the backstop that makes the prompt
// impossible to click past.
ipcMain.handle('pcvr-refresh-state', () => ({
  needsRefresh: pcvrInstaller.needsRefresh(),
  installedVersion: pcvrInstaller.installedVersion(),
  currentVersion: updater.currentVersion,
  installed: pcvrInstaller.isInstalled(),
}));

// Whether this machine can host PCVR at all (Windows x64, or LONGWAVE_FORCE_PCVR=1). The
// renderer hides the PCVR and Game library tabs outright when this is false — see
// pcvrInstaller.isSupportedHost() for why an arm64 Windows host is not merely "not installed".
ipcMain.handle('pcvr-supported', () => pcvrInstaller.isSupportedHost());

ipcMain.handle('pcvr-optin-pending', () => pcvrInstaller.optInPending());
ipcMain.handle('pcvr-optin-resolve', (_e, outcome) => {
  pcvrInstaller.markOptInHandled(outcome);
  return { ok: true };
});

/* Art is returned as a data: URL rather than a file:// path because the renderer's CSP allows
   `img-src 'self' data:` and nothing else. Widening it to `file:` to reach Steam's cache would be a
   real loosening for a cosmetic gain; base64 of a 30-40 KB jpg is cheap by comparison.

   Only paths the library itself reported (LibraryList through the 'rpc' bridge, recorded in
   allowedArt) are served, and only images, so this handler cannot be used as a general file
   reader even though the renderer is our own code. The cache is bounded: a grid scrolled through
   thousands of covers must not keep every one of them in memory. */
const ART_CACHE_LIMIT = 400;
const artCache = new Map();
const allowedArt = new Set();

/** Records the art paths of library titles: a whole LibraryList replaces the set (`replace`),
 *  while one title or list from any other library answer (an add, a kind change) only adds. */
function rememberLibraryArt(titles, replace = false) {
  if (!titles || typeof titles !== 'object') return;
  if (!Array.isArray(titles)) titles = [titles];
  if (replace) allowedArt.clear();
  for (const t of titles) {
    if (t && typeof t.portraitArt === 'string') allowedArt.add(t.portraitArt);
    if (t && typeof t.landscapeArt === 'string') allowedArt.add(t.landscapeArt);
  }
}

ipcMain.handle('game-art', async (_e, artPath) => {
  if (typeof artPath !== 'string' || artPath.length === 0) return null;
  if (artCache.has(artPath)) {
    const hit = artCache.get(artPath);
    artCache.delete(artPath);
    artCache.set(artPath, hit); // most recently used last
    return hit;
  }
  if (!allowedArt.has(artPath)) {
    console.warn('[main] refusing art the library did not report');
    return null;
  }
  const ext = path.extname(artPath).toLowerCase();
  const mime = ext === '.png' ? 'image/png' : ext === '.jpg' || ext === '.jpeg' ? 'image/jpeg' : null;
  if (!mime) return null;

  try {
    const url = `data:${mime};base64,${(await fs.promises.readFile(artPath)).toString('base64')}`;
    artCache.set(artPath, url);
    while (artCache.size > ART_CACHE_LIMIT) artCache.delete(artCache.keys().next().value);
    return url;
  } catch (e) {
    console.warn('[main] could not read art:', e.message);
    return null;
  }
});

// ---- PCVR service supervision (replaces the old per-service scheduled tasks) ----
ipcMain.handle('services-status', () => (supervisor ? supervisor.status() : {}));
ipcMain.handle('services-start', (_e, name) =>
  runStackOperation(() => supervisor.startChecked(name)));
ipcMain.handle('services-stop', (_e, name) =>
  runStackOperation(() => supervisor.stop(name)));
ipcMain.handle('services-start-stack', (_e, params) => {
  // The backstop for the version pairing above. Refusing here rather than only in the UI
  // matters because the stack can also be started from the headset and from a restored
  // session, neither of which passes through the renderer's prompt — and a mismatched bundle
  // does not fail cleanly, it fails as a pipe that connects and then misbehaves.
  if (pcvrInstaller.needsRefresh()) {
    throw new Error(
      `The installed PCVR component is for ${pcvrInstaller.installedVersion()} and this app is `
      + `${updater.currentVersion}. Download the matching version from the PCVR tab first.`);
  }
  return runStackOperation(() => supervisor.startStack((m, p) => routeClientFor(m).rpc(m, p), params));
});
ipcMain.handle('services-stop-stack', (_e, options) =>
  runStackOperation(() => supervisor.stopStack((m, p) => routeClientFor(m).rpc(m, p), options)));
ipcMain.handle('pcvr-desktop-quad', (_e, enabled) => supervisor.setDesktopQuad(enabled));
ipcMain.handle('vigem-status', () => pcvrInstaller.vigemBusStatus());
ipcMain.handle('vigem-install', () => runStackOperation(async () => {
  const status = pcvrInstaller.vigemBusStatus();
  if (status.installed) return status;
  await assertPcvrStoppedForDriverInstall();
  return pcvrInstaller.installVigemBus();
}));
ipcMain.handle('cloudxr-audio-status', () => pcvrInstaller.cloudXRAudioDriverStatus());
ipcMain.handle('cloudxr-audio-install', () => runStackOperation(async () => {
  const status = await pcvrInstaller.cloudXRAudioDriverStatus();
  if (status.installed) return status;
  // The runtime binds the driver's endpoints when it starts, so a driver installed under a
  // running stack is not picked up until the next PCVR start anyway.
  await assertPcvrStoppedForDriverInstall('the CloudXR audio driver');
  return pcvrInstaller.installCloudXRAudioDriver();
}));
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

if (gotSingleInstanceLock) {
  app.on('second-instance', (_event, argv, cwd, additionalData) => {
    // A second start that names a game launches it and nothing else: no window comes forward,
    // only the consent box or an error if one is due. A plain second start shows the window.
    const handed = additionalData && additionalData.launch;
    const game = (handed && (typeof handed.path === 'string' || typeof handed.titleId === 'string') && handed)
      || gameLauncher.gameRequestFromArgv(argv, { skip: ARGV_SKIP, cwd });
    if (game) launchFromCommandLine(game);
    else focusMainWindow();
  });
}

if (gotSingleInstanceLock) app.whenReady().then(() => {
  registerPcvrModuleProtocol();
  startBackend();
  startPcvrHost();
  supervisor = new Supervisor({
    appRoot: path.join(__dirname, '..'),
    logDirectory: logDirectory(),
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
  // Started by a game shortcut: come up in the tray, as if the window had been closed, and
  // launch the game once the pipes have had their chance to connect.
  createWindow({ show: !commandLineGame });
  createTray();
  pcvrClient.on('connected', () => sendLauncher('launcher-refresh'));
  pcvrClient.on('disconnected', () => sendLauncher('launcher-refresh'));
  client.on('connected', () => sendLauncher('launcher-refresh'));
  pcvrClient.on('notify', (event) => { if (event === 'foveated') sendLauncherMode(); });
  if (commandLineGame) {
    waitForLaunchPipes().then(() => launchFromCommandLine(commandLineGame));
  }
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
