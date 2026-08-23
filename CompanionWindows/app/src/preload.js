'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// Minimal, explicit surface exposed to the renderer. No Node, no ipcRenderer leakage.
contextBridge.exposeInMainWorld('hotspot', {
  // RPC to the backend.
  getStatus: () => ipcRenderer.invoke('rpc', 'GetStatus'),
  listUpstreams: () => ipcRenderer.invoke('rpc', 'ListUpstreamProfiles'),
  start: (params) => ipcRenderer.invoke('rpc', 'StartHotspot', params),
  stop: () => ipcRenderer.invoke('rpc', 'StopHotspot'),
  listWifiAdapters: () => ipcRenderer.invoke('rpc', 'ListWifiAdapters'),
  prepareApAdapter: () => ipcRenderer.invoke('rpc', 'PrepareApAdapter'),

  // Foveated Streaming (CloudXR session-management host).
  foveatedStart: (params) => ipcRenderer.invoke('rpc', 'FoveatedStart', params),
  foveatedStop: () => ipcRenderer.invoke('rpc', 'FoveatedStop'),
  foveatedStatus: () => ipcRenderer.invoke('rpc', 'FoveatedStatus'),
  // Reclaim the encoder and the OpenVR runtime: stops Sunshine and SteamVR, never OBS.
  foveatedStopConflicts: () => ipcRenderer.invoke('rpc', 'FoveatedStopConflicts'),

  // Game library. Curation is local-only by design: the headset receives the exposed subset and
  // has no way to browse this PC, so picking a file goes through the OS dialog below.
  gamesList: () => ipcRenderer.invoke('rpc', 'GamesList'),
  gamesSetExposed: (ids) => ipcRenderer.invoke('rpc', 'GamesSetExposed', { ids }),
  gamesSetOptimized: (id, enabled) => ipcRenderer.invoke('rpc', 'GamesSetOptimized', { id, enabled }),
  gamesAddCustom: (params) => ipcRenderer.invoke('rpc', 'GamesAddCustom', params),
  gamesRemoveCustom: (id) => ipcRenderer.invoke('rpc', 'GamesRemoveCustom', { id }),
  gamesLaunch: (id) => ipcRenderer.invoke('rpc', 'GamesLaunch', { id }),
  pickExecutable: () => ipcRenderer.invoke('pick-executable'),
  // Returns a data: URL (the CSP permits data: but not file:), or null when there is no art.
  gameArt: (artPath) => ipcRenderer.invoke('game-art', artPath),

  // PCVR services this app supervises itself (broker, sidecar) — no scheduled tasks and
  // no console windows. startStack/stopStack also drive the backend's own RPCs, in the one
  // order that works.
  servicesStatus: () => ipcRenderer.invoke('services-status'),
  serviceStart: (name) => ipcRenderer.invoke('services-start', name),
  serviceStop: (name) => ipcRenderer.invoke('services-stop', name),
  startPcvrStack: (params) => ipcRenderer.invoke('services-start-stack', params),
  stopPcvrStack: (options) => ipcRenderer.invoke('services-stop-stack', options),
  setDesktopQuad: (enabled) => ipcRenderer.invoke('pcvr-desktop-quad', enabled),
  confirmPcvrStop: () => ipcRenderer.invoke('confirm-pcvr-stop'),
  openPairingWindow: () => ipcRenderer.invoke('open-pairing-window'),
  openNoticesWindow: () => ipcRenderer.invoke('open-notices-window'),
  // Native screen streaming (Longwave "Native" protocol on port 4857).
  nativeStreamStatus: () => ipcRenderer.invoke('rpc', 'NativeStreamStatus'),
  nativeStreamSetEnabled: (enabled) => ipcRenderer.invoke('rpc', 'NativeStreamSetEnabled', { enabled }),
  nativeStreamSetInput: (params) => ipcRenderer.invoke('rpc', 'NativeStreamSetInput', params),
  nativeStreamRegenerateToken: () => ipcRenderer.invoke('rpc', 'NativeStreamRegenerateToken'),

  // Local helpers (no backend round-trip).
  genPassphrase: () => ipcRenderer.invoke('gen-passphrase'),
  genSsid: () => ipcRenderer.invoke('gen-ssid'),
  isConnected: () => ipcRenderer.invoke('get-connection'),
  // Whether the closed-source PCVR host process is installed and its pipe is currently up.
  // The real capability check for the Foveated/Games channels — call this, don't probe
  // typeof on the methods below, since every one of them is always defined here regardless
  // of whether the host is installed.
  pcvrAvailable: () => ipcRenderer.invoke('pcvr-available'),
  // On-demand PCVR bundle download — the closed-source host + broker + OpenXR layer never
  // ship in the public installer, so this is how a user with the OSS app gets them.
  pcvrCheckDownload: () => ipcRenderer.invoke('pcvr-check-download'),
  pcvrDownloadInstall: () => ipcRenderer.invoke('pcvr-download-install'),
  onPcvrDownloadProgress: (cb) => {
    const h = (_e, progress) => cb(progress);
    ipcRenderer.on('pcvr-download-progress', h);
    return () => ipcRenderer.removeListener('pcvr-download-progress', h);
  },
  // Whether the installed bundle was built for the app release now running. An app update
  // leaves them mismatched, and starting the stack in that state is blocked in main.js.
  pcvrRefreshState: () => ipcRenderer.invoke('pcvr-refresh-state'),
  // Whether the installer's PCVR checkbox was ticked and this user has not been asked yet.
  pcvrOptInPending: () => ipcRenderer.invoke('pcvr-optin-pending'),
  pcvrOptInResolve: (outcome) => ipcRenderer.invoke('pcvr-optin-resolve', outcome),

  // App self-update. Notify-only: checkUpdate() reports, downloadUpdate() fetches and
  // verifies against the release's signed manifest, installUpdate() quits and hands over to
  // the installer. Three calls, so nothing happens without a click.
  checkUpdate: (options) => ipcRenderer.invoke('update-check', options),
  downloadUpdate: () => ipcRenderer.invoke('update-download'),
  installUpdate: (installerPath) => ipcRenderer.invoke('update-install', installerPath),
  openReleasePage: () => ipcRenderer.invoke('update-open-page'),
  onUpdateProgress: (cb) => {
    const h = (_e, progress) => cb(progress);
    ipcRenderer.on('update-download-progress', h);
    return () => ipcRenderer.removeListener('update-download-progress', h);
  },

  // Tailscale (Foveated LAN/tailnet switch + DERP watchdog).
  tailscaleStatus: () => ipcRenderer.invoke('tailscale-status'),
  tailscalePath: (ip) => ipcRenderer.invoke('tailscale-path', ip),

  // Subscriptions. Return an unsubscribe fn.
  onConnection: (cb) => {
    const h = (_e, connected) => cb(connected);
    ipcRenderer.on('connection', h);
    return () => ipcRenderer.removeListener('connection', h);
  },
  // Fires whenever the PCVR host process connects/disconnects, so the UI can show/hide the
  // PCVR and Games tabs live rather than only checking pcvrAvailable() once at startup.
  onPcvrConnection: (cb) => {
    const h = (_e, connected) => cb(connected);
    ipcRenderer.on('pcvr-connection', h);
    return () => ipcRenderer.removeListener('pcvr-connection', h);
  },
  onNotify: (cb) => {
    const h = (_e, payload) => cb(payload);
    ipcRenderer.on('notify', h);
    return () => ipcRenderer.removeListener('notify', h);
  },
  onServices: (cb) => {
    const h = (_e, status) => cb(status);
    ipcRenderer.on('services', h);
    return () => ipcRenderer.removeListener('services', h);
  },

  // For content running inside a <webview> (e.g. the downloaded PCVR module's own pages,
  // which reuse this same preload) to reach back out to whatever hosts that <webview> —
  // generic on purpose, so it carries no PCVR-specific meaning itself. The host page
  // listens via the webview element's 'ipc-message' event.
  sendToShell: (channel, data) => ipcRenderer.sendToHost(channel, data),
  // The reverse direction: the shell calls <webview>.send('shell-command', ...) to reach into
  // a module's isolated page (e.g. "you're on-screen now, rescan"). Preload scripts keep
  // Node/ipcRenderer access regardless of contextIsolation, so this is where the relay into
  // the page's exposed API has to live.
  onShellCommand: (cb) => {
    const h = (_e, cmd, data) => cb(cmd, data);
    ipcRenderer.on('shell-command', h);
    return () => ipcRenderer.removeListener('shell-command', h);
  },
  // So renderer.js (sandboxed, no Node/__dirname of its own — and a sandboxed preload has
  // no __dirname either, so this script can't compute its own path) can point the PCVR/Games
  // <webview>s' own `preload` attribute at this same script — see main.js's comment on
  // ensurePcvrModuleLoaded() for why that's the same script, not a copy.
  preloadUrl: () => ipcRenderer.invoke('get-preload-url'),
});
