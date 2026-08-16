'use strict';
const $ = (id) => document.getElementById(id);

const el = {
  // Rail
  backendLamp: $('backendLamp'),
  backendText: $('backendText'),
  streamLamp: $('streamLamp'),
  streamChannelState: $('streamChannelState'),
  hotspotLamp: $('hotspotLamp'),
  hotspotChannelState: $('hotspotChannelState'),
  toast: $('toast'),

  // Screen streaming
  nsTransmit: $('nsTransmit'),
  nsLamp: $('nsLamp'),
  nsHeadline: $('nsHeadline'),
  nsViewer: $('nsViewer'),
  nsStartBtn: $('nsStartBtn'),
  nsStopBtn: $('nsStopBtn'),
  nsMsg: $('nsMsg'),
  nsHost: $('nsHost'),
  nsAddressWrap: $('nsAddressWrap'),
  nsAddressPick: $('nsAddressPick'),
  nsPort: $('nsPort'),
  nsToken: $('nsToken'),
  nsTokenHint: $('nsTokenHint'),
  nsRegenToken: $('nsRegenToken'),
  nsMouse: $('nsMouse'),
  nsKeyboard: $('nsKeyboard'),

  // PCVR (foveated / CloudXR)
  foveatedLamp: $('foveatedLamp'),
  foveatedChannelState: $('foveatedChannelState'),
  pcvrDownload: $('pcvrDownload'),
  pcvrDlTitle: $('pcvrDlTitle'),
  pcvrDlProgress: $('pcvrDlProgress'),
  pcvrDlBar: $('pcvrDlBar'),
  pcvrDlBtn: $('pcvrDlBtn'),
  pcvrDlStatus: $('pcvrDlStatus'),
  fovTransmit: $('fovTransmit'),
  fovLamp: $('fovLamp'),
  fovCloudXrBanner: $('fovCloudXrBanner'),
  fovPathBanner: $('fovPathBanner'),
  fovEncoderBanner: $('fovEncoderBanner'),
  fovEncoderIssues: $('fovEncoderIssues'),
  fovConflictBanner: $('fovConflictBanner'),
  fovConflictTitle: $('fovConflictTitle'),
  fovConflictList: $('fovConflictList'),
  fovConflictBtn: $('fovConflictBtn'),
  fovConflictSub: $('fovConflictSub'),
  fovPairingBanner: $('fovPairingBanner'),
  fovShowPairingBtn: $('fovShowPairingBtn'),
  noticesBtn: $('noticesBtn'),
  pcvrActionBtn: $('pcvrActionBtn'),
  pcvrStatusTitle: $('pcvrStatusTitle'),
  pcvrStatusDetail: $('pcvrStatusDetail'),
  pcvrOptions: $('pcvrOptions'),
  pcvrServices: $('pcvrServices'),
  pcvrDesktop: $('pcvrDesktop'),
  fovModeSelect: $('fovModeSelect'),
  fovQuality: $('fovQuality'),
  fovQualitySub: $('fovQualitySub'),
  fovVrchatOsc: $('fovVrchatOsc'),
  fovVrchatOscSub: $('fovVrchatOscSub'),
  fovPassthrough: $('fovPassthrough'),
  fovPassthroughSub: $('fovPassthroughSub'),
  fovTsSub: $('fovTsSub'),
  fovTsStatus: $('fovTsStatus'),
  fovBundleId: $('fovBundleId'),
  fovPort: $('fovPort'),
  fovIp: $('fovIp'),
  fovForceQr: $('fovForceQr'),
  fovOpMsg: $('fovOpMsg'),
  fovEndpoint: $('fovEndpoint'),
  fovClient: $('fovClient'),
  fovSession: $('fovSession'),
  fovCloudXr: $('fovCloudXr'),
  fovAdvertising: $('fovAdvertising'),
  fovBundleShown: $('fovBundleShown'),
  svcList: $('svcList'),

  // Game library
  gamesFilter: $('gamesFilter'),
  gamesAddBtn: $('gamesAddBtn'),
  gamesRefreshBtn: $('gamesRefreshBtn'),
  gamesList: $('gamesList'),
  gamesCount: $('gamesCount'),
  gamesOpMsg: $('gamesOpMsg'),

  // Hotspot
  capabilityBanner: $('capabilityBanner'),
  apTransmit: $('apTransmit'),
  apLamp: $('apLamp'),
  apHeadline: $('apHeadline'),
  apDetail: $('apDetail'),
  startBtn: $('startBtn'),
  stopBtn: $('stopBtn'),
  fixAdapterBtn: $('fixAdapterBtn'),
  opMsg: $('opMsg'),
  joinPanel: $('joinPanel'),
  joinSsid: $('joinSsid'),
  joinPass: $('joinPass'),
  joinPassHint: $('joinPassHint'),
  joinGateway: $('joinGateway'),
  apSettingsHint: $('apSettingsHint'),
  ssid: $('ssid'),
  passphrase: $('passphrase'),
  band: $('band'),
  upstream: $('upstream'),
  regen: $('regen'),
};

/** The address the operator picked, kept for as long as the window is open. */
let preferredAddress = null;

let backendConnected = false;
let tsInfo = { installed: false, backendState: 'unknown', selfIp: null, selfName: null };
let lastFoveated = null;
let lastServices = {};
let pcvrBusy = false;
/* Which way the in-flight operation is going ('start' | 'stop' | null). The busy
   labels used to derive direction from pcvrActive(), but that is LIVE state: a
   start flips it to true the moment the first service comes up, so the panel read
   "Stopping PCVR" halfway through starting. The operation knows its own direction;
   the state does not. */
let pcvrBusyOp = null;
let lanAdvertiseIp = '';

/* This page runs in two hosts, and the PCVR host is a separate, closed-source process with
   its own pipe that may simply not be installed. Electron always defines the Foveated- and
   Games-prefixed wrappers (they just fail if the host isn't there), and the WebView2 shell
   never defines pcvrAvailable at all — so the real check is "ask the main process whether
   that pipe is actually connected right now", not a typeof probe on methods that exist either
   way. */
let hasPcvr = false;

// ── Small helpers ──────────────────────────────────────────────────────────

function setLamp(lamp, state) {
  if (lamp) lamp.dataset.state = state;
}

/**
 * Writes a value that has to be retyped on the headset. Returns whether it was
 * split into reading groups, so the caller can show the caption that warns the
 * gaps are not really there.
 */
function setReadout(node, value, { chunk = false } = {}) {
  const text = value || '';
  node.dataset.value = text;
  if (!text) {
    node.textContent = '—';
    return false;
  }
  // Only group a run of plain characters. A value that already carries its own
  // separators reads fine as it is, and slicing it every four would fight them.
  if (!chunk || text.length < 8 || !/^[A-Za-z0-9]+$/.test(text)) {
    node.textContent = text;
    return false;
  }
  node.textContent = '';
  for (let i = 0; i < text.length; i += 4) {
    const group = document.createElement('span');
    group.className = 'grp';
    group.textContent = text.slice(i, i + 4);
    node.appendChild(group);
  }
  return true;
}

function setNote(node, text, kind) {
  node.textContent = text || '';
  node.className = 'note' + (kind ? ' is-' + kind : '') + (text ? '' : ' hidden');
}

let toastTimer = null;
function toast(text) {
  el.toast.textContent = text;
  el.toast.classList.add('is-shown');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.toast.classList.remove('is-shown'), 2200);
}

/** Whether a download/install is currently in flight — disables re-entry and gets checked
 *  by renderPcvrDownloadPanel() to keep the button/status text consistent mid-operation. */
let pcvrInstalling = false;
/** Last result of checkAvailability(), or null before the first check has come back. */
let pcvrDownloadInfo = null;

const PCVR_DOWNLOAD_REASON_TEXT = {
  'dev-build': 'Not available in a local dev build — this only works in a released app, which knows which GitHub release to ask for.',
  'release-not-found': "This build's release doesn't exist (or was deleted) on GitHub.",
  'asset-missing': "Not published yet for this app version. Check back after it's uploaded.",
  'network-error': 'Could not reach GitHub. Check your connection and try again.',
  'error': 'Something went wrong checking for the download.',
};

async function refreshPcvrDownloadState() {
  if (typeof window.hotspot.pcvrCheckDownload !== 'function') return;
  pcvrDownloadInfo = await window.hotspot.pcvrCheckDownload();
  renderPcvrDownloadPanel();
}

function renderPcvrDownloadPanel() {
  if (hasPcvr || pcvrInstalling) return;
  const info = pcvrDownloadInfo;
  el.pcvrDlBtn.disabled = !info || !info.available;
  if (!info) {
    el.pcvrDlTitle.textContent = 'PCVR isn’t installed';
    el.pcvrDlStatus.textContent = 'Checking…';
  } else if (info.available) {
    el.pcvrDlTitle.textContent = info.installedVersion && !info.upToDate
      ? 'A newer PCVR build is available'
      : 'PCVR isn’t installed';
    const mb = info.size ? `${(info.size / (1024 * 1024)).toFixed(0)} MB` : null;
    el.pcvrDlStatus.textContent = mb ? `${mb} download` : '';
  } else {
    el.pcvrDlTitle.textContent = 'PCVR isn’t available to download';
    el.pcvrDlStatus.textContent = PCVR_DOWNLOAD_REASON_TEXT[info.reason] || info.reason || '';
  }
}

async function onDownloadPcvr() {
  if (pcvrInstalling || !pcvrDownloadInfo?.available) return;
  pcvrInstalling = true;
  el.pcvrDlBtn.disabled = true;
  el.pcvrDlProgress.classList.remove('hidden');
  el.pcvrDlBar.style.width = '0%';
  el.pcvrDlTitle.textContent = 'Downloading PCVR…';
  el.pcvrDlStatus.textContent = '';
  try {
    await window.hotspot.pcvrDownloadInstall();
    el.pcvrDlTitle.textContent = 'Installed — waiting for it to connect…';
    el.pcvrDlStatus.textContent = '';
  } catch (e) {
    el.pcvrDlTitle.textContent = 'Install failed';
    el.pcvrDlStatus.textContent = e.message || String(e);
  } finally {
    pcvrInstalling = false;
    el.pcvrDlProgress.classList.add('hidden');
    // hasPcvr flips (and re-renders this panel away) once the host's pipe actually
    // connects, via onPcvrConnection below — not immediately here, since the spawned
    // process still has to bind the pipe.
    if (!hasPcvr) { el.pcvrDlBtn.disabled = false; refreshPcvrDownloadState(); }
  }
}

function onPcvrDownloadProgress(progress) {
  if (progress.phase === 'downloading' && progress.total) {
    const pct = Math.min(100, Math.round((progress.received / progress.total) * 100));
    el.pcvrDlBar.style.width = `${pct}%`;
    el.pcvrDlStatus.textContent = `${pct}%`;
  } else if (progress.phase === 'verifying') {
    el.pcvrDlStatus.textContent = 'Verifying…';
  } else if (progress.phase === 'extracting') {
    el.pcvrDlStatus.textContent = 'Installing…';
  } else if (progress.phase === 'registering') {
    el.pcvrDlStatus.textContent = 'Registering the OpenXR layer — approve the prompt if Windows asks.';
  }
}

/** Shows or hides the PCVR download banner and the rest of each PCVR-gated view to match
 *  live host availability. The nav tabs and the views themselves stay reachable either way —
 *  that's the point: opening the PCVR tab with nothing installed yet is how you install it. */
function applyHostCapabilities() {
  el.pcvrDownload.classList.toggle('hidden', hasPcvr);
  for (const id of ['fovTransmit', 'pcvrOptions', 'fovRunPanel']) {
    $(id).classList.toggle('hidden', !hasPcvr);
  }
  if (hasPcvr) pcvrDownloadInfo = null;
  else refreshPcvrDownloadState();
  renderGames();
}

function showView(viewId) {
  for (const tab of document.querySelectorAll('.channel')) {
    const current = tab.dataset.view === viewId;
    tab.classList.toggle('is-current', current);
    tab.setAttribute('aria-selected', String(current));
    $(tab.dataset.view).classList.toggle('hidden', !current);
  }
  // Scanning the Steam libraries touches the disk, so only do it when the tab
  // is actually being looked at.
  if (viewId === 'gamesView') refreshGames();
}

// ── Backend connection ─────────────────────────────────────────────────────

function setBackendConnected(connected) {
  backendConnected = connected;
  setLamp(el.backendLamp, connected ? 'live' : 'fault');
  el.backendText.textContent = connected
    ? 'Companion services running'
    : 'Companion services unreachable';
  el.startBtn.disabled = !connected;
  el.nsStartBtn.disabled = !connected;
  renderPcvrSummary();
  if (!connected) return;
  refreshAll();
  /* And the game library, if it never loaded. The library is deliberately lazy
     — a Steam scan touches the disk, so it only runs when the tab is looked at
     — but that made the app needlessly unrecoverable: open Games in the second
     before the backend's pipe is up, the one attempt fails, and the tab stays
     empty with no way back except restarting. Which is what people did. */
  if (gamesCache.length === 0) refreshGames();
}

// ── PCVR summary ───────────────────────────────────────────────────────────

async function refreshFoveatedStatus() {
  if (!hasPcvr || !backendConnected) return;
  try {
    renderFoveated(await window.hotspot.foveatedStatus());
  } catch {
    // Connection state already owns the unavailable message; retry next interval.
  }
}

function fovMode() {
  return el.fovModeSelect.value || 'lan';
}

function servicesActive() {
  return Object.values(lastServices).some((service) => service.healthy || service.running);
}

function pcvrActive() {
  return Boolean(lastFoveated && ['on', 'starting'].includes(lastFoveated.state)) || servicesActive();
}

function renderPcvrSummary() {
  if (!hasPcvr) return;
  const active = pcvrActive();
  const f = lastFoveated || {};
  const serviceCount = Object.keys(lastServices).length;
  const healthyCount = Object.values(lastServices).filter((service) => service.healthy).length;
  const partial = serviceCount > 0 && healthyCount > 0 && healthyCount < serviceCount;
  const busy = pcvrBusy || f.state === 'starting';

  const state = (f.state === 'error' || partial) ? 'fault'
    : busy ? 'waiting'
    : (f.clientConnected || f.gameRunning) ? 'live'
    : active ? 'waiting'
    : 'off';
  el.fovTransmit.dataset.state = state;
  setLamp(el.fovLamp, state);
  setLamp(el.foveatedLamp, state);
  el.foveatedChannelState.textContent =
    { off: 'Off', waiting: 'Ready', live: 'Streaming', fault: 'Needs attention' }[state];

  el.pcvrActionBtn.textContent = pcvrBusy ? (pcvrBusyOp === 'stop' ? 'Stopping…' : 'Starting…')
    : active ? 'Stop PCVR' : 'Start PCVR';
  el.pcvrActionBtn.classList.toggle('key-stop', active && !pcvrBusy);
  el.pcvrActionBtn.disabled = pcvrBusy || (!backendConnected && !active);

  if (!backendConnected) {
    el.pcvrStatusTitle.textContent = 'Companion services unavailable';
    el.pcvrStatusDetail.textContent = 'Waiting for the local backend to reconnect.';
  } else if (pcvrBusy) {
    const stopping = pcvrBusyOp === 'stop';
    el.pcvrStatusTitle.textContent = stopping ? 'Stopping PCVR' : 'Starting PCVR';
    el.pcvrStatusDetail.textContent = stopping
      ? 'Closing the session and returning system settings.'
      : 'Preparing CloudXR and the OpenXR session.';
  } else if (f.state === 'error' || partial) {
    el.pcvrStatusTitle.textContent = 'PCVR needs attention';
    el.pcvrStatusDetail.textContent = f.detail || 'One or more PCVR services did not start correctly.';
  } else if (f.titleRunning) {
    // Deliberately not f.gameRunning: the broker is itself an OpenXR app, so that bit is
    // true for any live session. Only a launched title counts as "a game is running".
    el.pcvrStatusTitle.textContent = 'Game streaming';
    el.pcvrStatusDetail.textContent = f.titleName
      ? `${f.titleName} is connected to the CloudXR runtime.`
      : 'An OpenXR game is connected to the CloudXR runtime.';
  } else if (f.clientConnected) {
    el.pcvrStatusTitle.textContent = 'Vision Pro connected';
    el.pcvrStatusDetail.textContent = f.sessionStatus || 'The headset is connected to this PC.';
  } else if (active) {
    el.pcvrStatusTitle.textContent = 'Waiting for the headset';
    el.pcvrStatusDetail.textContent = 'Open Longwave on the headset to connect.';
  } else {
    el.pcvrStatusTitle.textContent = 'PCVR is off';
    el.pcvrStatusDetail.textContent = 'Start when you are ready to connect from Vision Pro.';
  }

  // These are read once when the host starts, so editing them mid-session would
  // be a lie. Lock them while it runs and while an operation is in flight.
  for (const control of [
    el.pcvrServices, el.fovModeSelect, el.fovQuality, el.fovVrchatOsc,
    el.fovBundleId, el.fovPort, el.fovIp, el.fovForceQr,
  ]) control.disabled = active || pcvrBusy;
  /* The desktop panel is the exception: the broker creates and tears it down on demand,
     so this one stays live while a session runs. That is the point of it — you decide you
     want the desktop in the middle of a game, not before you start one. */
  el.pcvrDesktop.disabled = pcvrBusy;
  /* Passthrough is the other exception, for the opposite reason: it cannot be changed
     under a running stack at all, so instead of greying out it restarts PCVR for you. */
  el.fovPassthrough.disabled = pcvrBusy;
}

// ── Screen streaming ───────────────────────────────────────────────────────

function renderNativeStream(s) {
  if (!s) return;
  const running = !!s.running;
  const connected = running && !!s.connectedDevice;
  const broken = !s.captureSupported || !!s.lastError;

  const state = broken ? 'fault' : connected ? 'live' : running ? 'waiting' : 'off';
  el.nsTransmit.dataset.state = state;
  setLamp(el.nsLamp, state);
  setLamp(el.streamLamp, state);
  el.streamChannelState.textContent =
    { off: 'Off', waiting: 'Waiting', live: 'Streaming', fault: 'Needs attention' }[state];

  if (connected) {
    el.nsHeadline.textContent = `Streaming to ${s.connectedDevice}`;
    el.nsViewer.textContent = 'The desktop and any windows the headset picks are going out now.';
  } else if (running) {
    el.nsHeadline.textContent = 'Waiting for the headset';
    el.nsViewer.textContent = 'Add a Native connection in Longwave using the details below.';
  } else {
    el.nsHeadline.textContent = 'Streaming is off';
    el.nsViewer.textContent = 'Start it, then connect from the headset.';
  }

  el.nsStartBtn.classList.toggle('hidden', running);
  el.nsStopBtn.classList.toggle('hidden', !running);

  if (!s.captureSupported) {
    setNote(el.nsMsg, 'This Windows build cannot capture the screen. Windows 10 version 1903 or newer is required.', 'error');
  } else if (s.lastError) {
    setNote(el.nsMsg, s.lastError, 'error');
  } else {
    setNote(el.nsMsg, '');
  }

  renderAddresses(s.addresses || []);
  setReadout(el.nsPort, String(s.port || 4857));
  const tokenGrouped = setReadout(el.nsToken, s.token || '', { chunk: true });
  el.nsTokenHint.classList.toggle('hidden', !tokenGrouped);
  el.nsMouse.checked = !!s.mouseControlEnabled;
  el.nsKeyboard.checked = !!s.keyboardControlEnabled;
}

function renderAddresses(addresses) {
  if (addresses.length === 0) {
    setReadout(el.nsHost, '');
    el.nsAddressWrap.classList.add('hidden');
    return;
  }
  if (!addresses.includes(preferredAddress)) preferredAddress = addresses[0];
  setReadout(el.nsHost, preferredAddress);

  // Only worth a picker when this PC has more than one address to offer.
  el.nsAddressWrap.classList.toggle('hidden', addresses.length < 2);
  if (addresses.length < 2) return;
  el.nsAddressPick.innerHTML = '';
  for (const address of addresses) {
    const option = document.createElement('option');
    option.value = address;
    option.textContent = address;
    el.nsAddressPick.appendChild(option);
  }
  el.nsAddressPick.value = preferredAddress;
}

async function refreshNativeStream() {
  try {
    renderNativeStream(await window.hotspot.nativeStreamStatus());
  } catch (e) {
    setNote(el.nsMsg, 'Could not read the streaming status: ' + e.message, 'error');
  }
}

// ── Hotspot ────────────────────────────────────────────────────────────────

function renderStatus(s) {
  if (!s) return;
  const on = s.state === 'on';
  const clients = s.clientCount ?? 0;
  const state = s.state === 'inTransition' ? 'waiting' : on ? (clients > 0 ? 'live' : 'waiting') : 'off';

  el.apTransmit.dataset.state = state;
  setLamp(el.apLamp, state);
  setLamp(el.hotspotLamp, state);
  el.hotspotChannelState.textContent =
    { off: 'Off', waiting: on ? 'Waiting' : 'Starting', live: 'Joined' }[state];

  if (on && clients > 0) {
    const room = s.maxClientCount ? ` of ${s.maxClientCount}` : '';
    el.apHeadline.textContent = clients === 1 ? `1 device joined${room}` : `${clients} devices joined${room}`;
    el.apDetail.textContent = `Sharing internet from ${s.upstreamName || 'this PC'}.`;
  } else if (on) {
    el.apHeadline.textContent = 'Waiting for the headset';
    el.apDetail.textContent = 'The network is up. Join it from Settings → Wi-Fi on the headset.';
  } else {
    el.apHeadline.textContent = 'Hotspot is off';
    el.apDetail.textContent = 'Windows may ask for administrator approval when it starts.';
  }

  el.startBtn.classList.toggle('hidden', on);
  el.stopBtn.classList.toggle('hidden', !on);

  if (s.canHostAp === false) {
    el.capabilityBanner.classList.remove('hidden');
    el.capabilityBanner.textContent =
      s.capabilityDetail || 'This PC may not be able to host a Wi-Fi hotspot. Its Wi-Fi adapter does not report SoftAP support.';
  } else {
    el.capabilityBanner.classList.add('hidden');
  }

  // A running AP ignores edits to these until it is restarted, so say so
  // rather than letting someone type into a field that does nothing.
  el.apSettingsHint.classList.toggle('hidden', !on);
  for (const field of [el.ssid, el.passphrase, el.band, el.upstream, el.regen]) field.disabled = on;

  el.joinPanel.classList.toggle('hidden', !on);
  if (on) {
    setReadout(el.joinSsid, s.ssid || '');
    const passGrouped = setReadout(el.joinPass, s.passphrase || '', { chunk: true });
    el.joinPassHint.classList.toggle('hidden', !passGrouped);
    setReadout(el.joinGateway, s.gatewayIp || '192.168.137.1');
  }
}

async function loadUpstreams() {
  try {
    const list = await window.hotspot.listUpstreams();
    const previous = el.upstream.value;
    el.upstream.innerHTML = '';
    for (const p of list) {
      const option = document.createElement('option');
      option.value = p.id;
      const kind = p.kind === 'ethernet' ? 'Ethernet' : p.kind === 'wifi' ? 'Wi-Fi' : p.kind;
      let label = `${p.name} (${kind})`;
      if (p.isDefault) label += ' • default';
      if (!p.hasInternet) label += ' • no internet';
      if (p.tetheringCapability !== 'enabled') label += ` • ${p.tetheringCapability}`;
      option.textContent = label;
      el.upstream.appendChild(option);
    }
    const fallback = list.find((p) => p.isDefault) || list[0];
    el.upstream.value = list.some((p) => p.id === previous) ? previous : (fallback ? fallback.id : '');
  } catch (e) {
    setNote(el.opMsg, 'Could not list the internet connections: ' + e.message, 'error');
  }
}

async function refreshAll() {
  try {
    await loadUpstreams();
    await refreshNativeStream();
    const s = await window.hotspot.getStatus();
    // Seed the fields from the live AP when one is running; otherwise the
    // generated defaults stay put.
    if (s.state === 'on') {
      if (s.ssid) el.ssid.value = s.ssid;
      if (s.passphrase) el.passphrase.value = s.passphrase;
      if (s.band) el.band.value = s.band;
    }
    renderStatus(s);
  } catch (e) {
    setNote(el.opMsg, 'Could not read the hotspot status: ' + e.message, 'error');
  }
  if (!hasPcvr) return;
  try {
    renderFoveated(await window.hotspot.foveatedStatus());
  } catch (e) {
    setFovOpMsg('Could not read the PCVR status: ' + e.message, 'error');
  }
}

async function onStart() {
  setNote(el.opMsg, 'Starting the hotspot…');
  el.startBtn.disabled = true;
  try {
    const res = await window.hotspot.start({
      ssid: el.ssid.value.trim() || undefined,
      passphrase: el.passphrase.value.trim() || undefined,
      band: el.band.value,
      profileId: el.upstream.value || undefined,
    });
    if (res.ok) {
      setNote(el.opMsg, '');
      toast('Hotspot started');
      el.fixAdapterBtn.classList.add('hidden');
    } else {
      setNote(el.opMsg, res.detail || `The hotspot did not start (${res.status}).`, 'error');
      // Offer the guided fix when an adapter that cannot host is in the way of
      // one that can.
      el.fixAdapterBtn.classList.toggle('hidden', res.status !== 'adapterConflict');
    }
    renderStatus(res.snapshot);
  } catch (e) {
    setNote(el.opMsg, 'The hotspot did not start: ' + e.message, 'error');
  } finally {
    el.startBtn.disabled = !(await window.hotspot.isConnected());
  }
}

async function onFixAdapter() {
  setNote(el.opMsg, 'Turning off the conflicting adapter…');
  el.fixAdapterBtn.disabled = true;
  try {
    const r = await window.hotspot.prepareApAdapter();
    if (!r.ok) {
      setNote(el.opMsg, r.detail || 'No adapter on this PC can host a hotspot.', 'error');
      return;
    }
    el.fixAdapterBtn.classList.add('hidden');
    await onStart(); // retry now that the capable radio is the only Wi-Fi adapter
  } catch (e) {
    setNote(el.opMsg, 'Could not turn off the adapter: ' + e.message, 'error');
  } finally {
    el.fixAdapterBtn.disabled = false;
  }
}

async function onStop() {
  setNote(el.opMsg, 'Stopping the hotspot…');
  el.stopBtn.disabled = true;
  try {
    const res = await window.hotspot.stop();
    if (res.ok) {
      setNote(el.opMsg, '');
      toast('Hotspot stopped');
    } else {
      setNote(el.opMsg, res.detail || `The hotspot did not stop (${res.status}).`, 'error');
    }
    if (res.snapshot) renderStatus(res.snapshot);
  } catch (e) {
    setNote(el.opMsg, 'The hotspot did not stop: ' + e.message, 'error');
  } finally {
    el.stopBtn.disabled = false;
  }
}

async function copyReadout(id) {
  const node = $(id);
  const text = node.dataset.value || node.textContent;
  try {
    await navigator.clipboard.writeText(text);
    toast(`Copied ${text}`);
  } catch {
    toast('Could not copy — select the value and press Ctrl+C');
  }
}

// ───────────────── Foveated Streaming (CloudXR) ─────────────────

function setFovOpMsg(text, kind) {
  setNote(el.fovOpMsg, text, kind === 'error' ? 'error' : kind === 'ok' ? 'ok' : null);
}

// Refresh Tailscale node status and reflect it in the mode UI.
async function refreshTailscale() {
  if (!hasPcvr) return;
  try {
    tsInfo = await window.hotspot.tailscaleStatus();
  } catch {
    tsInfo = { installed: false, backendState: 'unknown', selfIp: null, selfName: null };
  }
  el.fovTsStatus.textContent = tsInfo.installed
    ? `${tsInfo.backendState}${tsInfo.selfIp ? ' · ' + tsInfo.selfIp : ''}`
    : 'not installed';
  el.fovTsSub.textContent = tsInfo.selfIp
    ? `Serve on ${tsInfo.selfIp} — for remote / cloud hosts (EC2 → home)`
    : 'Tailscale not running — start it to use this mode';
  applyMode();
}

// LAN vs Tailscale mode: in tailnet mode the advertise IP is pinned to the tailnet
// self-IP (and locked); LAN mode leaves it auto. Disabled while the host runs.
function applyMode() {
  const running = lastFoveated && (lastFoveated.state === 'on' || lastFoveated.state === 'starting');
  el.fovModeSelect.disabled = !!running || pcvrBusy;
  if (fovMode() === 'tailnet') {
    if (!el.fovIp.readOnly) lanAdvertiseIp = el.fovIp.value.trim();
    if (tsInfo.selfIp) el.fovIp.value = tsInfo.selfIp;
    el.fovIp.readOnly = true;
    el.fovIp.placeholder = 'Tailscale IP';
  } else {
    if (el.fovIp.readOnly) el.fovIp.value = lanAdvertiseIp;
    el.fovIp.readOnly = false;
    el.fovIp.placeholder = 'Automatic';
  }
  renderPcvrSummary();
}

// DERP watchdog: while a tailnet-mode client is connected, ping it and warn loudly
// if the path is relayed (DERP can't carry the 4×4096² streams).
async function refreshPath() {
  if (!hasPcvr) return;
  const f = lastFoveated;
  const running = f && f.state === 'on';
  if (fovMode() !== 'tailnet' || !running || !f.clientConnected || !f.clientAddress) {
    el.fovPathBanner.classList.add('hidden');
    return;
  }
  const ip = String(f.clientAddress).replace(/^\[/, '').replace(/\]?:\d+$/, '');
  let r;
  try { r = await window.hotspot.tailscalePath(ip); } catch { return; }
  el.fovPathBanner.classList.remove('hidden');
  if (r.direct) {
    el.fovPathBanner.className = 'banner banner-good';
    el.fovPathBanner.textContent = `Direct Tailscale path to ${ip}: ${r.detail}`;
  } else {
    el.fovPathBanner.className = 'banner';
    el.fovPathBanner.textContent = `${r.detail || 'Path unknown'} — DERP cannot carry the video streams. ` +
      'Open UDP 41641 between the peers so WireGuard connects directly.';
  }
}

function renderFoveated(f) {
  if (!f) return;
  lastFoveated = f;

  const on = f.state === 'on' || f.state === 'starting';
  applyMode();

  // CloudXR availability banner.
  if (on && f.cloudXrAvailable === false) {
    el.fovCloudXrBanner.classList.remove('hidden');
    el.fovCloudXrBanner.textContent = f.cloudXrDetail
      || 'CloudXR is not installed. Discovery and pairing work, but video cannot stream.';
  } else {
    el.fovCloudXrBanner.classList.add('hidden');
  }

  if (f.state === 'error') {
    setFovOpMsg(f.detail || 'Host error.', 'error');
  }

  /* Conflicts before encoder findings, because these are the ones with a button. The encoder
     banner stays as it was: advice about capacity we cannot act on. */
  const conflicts = Array.isArray(f.conflicts) ? f.conflicts : [];
  el.fovConflictBanner.classList.toggle('hidden', conflicts.length === 0);
  if (conflicts.length > 0) {
    el.fovConflictList.replaceChildren();
    for (const c of conflicts) {
      const item = document.createElement('li');
      const name = document.createElement('strong');
      name.textContent = c.name;
      item.append(name, document.createTextNode(` — ${c.reason}`));
      el.fovConflictList.appendChild(item);
    }
    const stoppable = conflicts.filter((c) => c.canStop);
    /* The button only ever claims what it will actually do. Naming the programs matters: a
       generic "Fix" on something that force-closes the user's game-stream host would be a
       nasty surprise, and OBS is deliberately excluded so it must not be implied. */
    el.fovConflictBtn.classList.toggle('hidden', stoppable.length === 0);
    el.fovConflictBtn.textContent = `Stop ${stoppable.map((c) => c.name).join(' and ')}`;
    el.fovConflictSub.textContent = stoppable.some((c) => c.id === 'sunshine')
      ? 'Sunshine is a service, so Windows may ask for administrator approval. It is started again when PCVR stops.'
      : '';
  }

  const encoderIssues = Array.isArray(f.encoderIssues) ? f.encoderIssues : [];
  el.fovEncoderBanner.classList.toggle('hidden', encoderIssues.length === 0);
  el.fovEncoderIssues.replaceChildren();
  for (const issue of encoderIssues) {
    const item = document.createElement('li');
    item.textContent = issue;
    el.fovEncoderIssues.appendChild(item);
  }

  el.fovAdvertising.textContent = f.advertising ? 'On' : 'Off';
  el.fovBundleShown.textContent = f.bundleId || '—';
  el.fovEndpoint.textContent = on ? `${f.ipAddress || '—'}:${f.port}` : '—';
  /* The host builds its CloudXR controller when it starts, so while PCVR is off this flag
     means "not asked yet", not "absent" — and printing "Not installed" there reads as a
     fault on a machine where CloudXR is fine, which is a confusing thing to see right
     above the button you are about to press. */
  el.fovCloudXr.textContent = f.cloudXrAvailable
    ? (f.runtimeRunning ? 'Runtime running' : 'Available')
    : (on ? 'Not installed' : 'Checked when PCVR starts');
  el.fovClient.textContent = f.clientConnected ? (f.clientAddress || 'Connected') : 'Not connected';
  el.fovSession.textContent = f.titleRunning
    ? (f.titleName || 'Game running')
    : (f.sessionStatus || 'Idle');

  // The QR itself belongs to a large, masked-by-default window managed by the main process.
  if (f.pairingRequired && (f.qrPngDataUri || f.qrPayload)) {
    showView('foveatedView');
    el.fovPairingBanner.classList.remove('hidden');
  } else {
    el.fovPairingBanner.classList.add('hidden');
  }

  /* Quality subtitle mirrors the host's ground truth, because the dropdown is only a
     request: the yaml can be hand-tuned ("custom"), and a change written while the
     CloudXR service was already running only lands on the next full start. */
  if (f.qualityPendingRestart) {
    el.fovQualitySub.textContent = 'New quality saved — applies on the next PCVR start.';
  } else if (f.quality === 'custom') {
    el.fovQualitySub.textContent = 'Host is hand-tuned (custom yaml values); the preset applies on next start.';
  } else if (f.quality && f.quality !== el.fovQuality.value) {
    el.fovQualitySub.textContent = `Host is currently set to ${f.quality}.`;
  } else {
    el.fovQualitySub.textContent = 'Applies when PCVR starts.';
  }

  /* Same reconciliation for the OSC gate, and for the same reason: the dropdown is a
     request, the registry is the fact. It is also settable outside this app (the env var,
     or the registry directly), so the panel must never claim a state the host is not in. */
  const oscWanted = el.fovVrchatOsc.value === 'on';
  if (typeof f.vrchatOsc === 'boolean' && f.vrchatOsc !== oscWanted) {
    el.fovVrchatOscSub.textContent = f.vrchatOsc
      ? 'Host currently has it ON; your change applies on the next PCVR start.'
      : 'Host currently has it OFF; your change applies on the next PCVR start.';
  } else {
    el.fovVrchatOscSub.textContent = oscWanted
      ? 'Your headset\'s eye tracking drives your avatar\'s eyes. Overrides any other OSC eye-tracking app on this PC.'
      : 'Off — VRChat uses its own automatic eye look.';
  }

  /* Passthrough reconciles the same way, and matters more: this one costs bitrate on
     every frame, so a panel showing "off" over a host that is streaming alpha would be
     hiding a real cost. Unlike the others it restarts PCVR on change, so there is no
     "applies next start" state to report — either it is on or the restart failed. */
  const passthroughWanted = el.fovPassthrough.value === 'on';
  if (typeof f.passthrough === 'boolean' && f.passthrough !== passthroughWanted) {
    el.fovPassthroughSub.textContent = f.passthrough
      ? 'Host is currently streaming alpha; restart PCVR to turn it off.'
      : 'Host is not streaming alpha; restart PCVR to turn it on.';
  } else {
    el.fovPassthroughSub.textContent = passthroughWanted
      ? 'Pure green (00FF00) in a game becomes your real room. Costs encoder time and bitrate on every frame.'
      : 'Off — the game fills the whole picture, and no alpha channel is encoded.';
  }

  renderPcvrSummary();
  refreshPath();
}

/**
 * The desktop panel, switched while a session is live.
 *
 * Optimistic on the way in — the switch has already moved and arguing with it would feel
 * broken — but put back if the broker refuses, because a switch left on over a panel that
 * never appeared is worse than one that visibly snaps back with a reason.
 */
async function onDesktopQuadToggled() {
  const wanted = el.pcvrDesktop.checked;
  savePcvrOptions();
  const hint = document.getElementById('pcvrDesktopHint');
  const originalHint = hint ? hint.dataset.original || hint.textContent : '';
  if (hint && !hint.dataset.original) hint.dataset.original = originalHint;
  try {
    await window.hotspot.setDesktopQuad(wanted);
    if (hint) hint.textContent = hint.dataset.original;
  } catch (e) {
    el.pcvrDesktop.checked = !wanted;
    savePcvrOptions();
    if (hint) hint.textContent = `Could not ${wanted ? 'show' : 'hide'} the desktop: ${e.message}`;
  }
}

function pcvrStartParams() {
  const port = parseInt(el.fovPort.value, 10);
  return {
    bundleId: el.fovBundleId.value.trim() || undefined,
    port: Number.isFinite(port) ? port : undefined,
    ipAddress: fovMode() === 'tailnet'
      ? (tsInfo.selfIp || undefined)
      : (el.fovIp.value.trim() || undefined),
    forceQrCode: el.fovForceQr.checked,
    quality: el.fovQuality.value || undefined,
    // Tri-state on the wire: only send a boolean, never undefined-as-false, so a host
    // configured by hand is not clobbered by a panel that happens to be showing "Off".
    vrchatOsc: el.fovVrchatOsc.value === 'on',
    // Same tri-state reasoning: a boolean, never undefined-as-false.
    passthrough: el.fovPassthrough.value === 'on',
    // Read by the supervisor and stripped before the host RPC — the broker shows the
    // desktop panel, and the foveated host has no opinion about it.
    desktopQuad: el.pcvrDesktop.checked,
  };
}

/* Reclaim the encoder and the OpenVR runtime. Disabled while it runs, because stopping a
   service can sit on a UAC prompt for as long as the user takes to answer it, and a button that
   still looks pressable invites a second prompt on top of the first. */
async function onStopConflicts() {
  el.fovConflictBtn.disabled = true;
  const label = el.fovConflictBtn.textContent;
  el.fovConflictBtn.textContent = 'Stopping…';
  try {
    const result = await window.hotspot.foveatedStopConflicts();
    if (result && result.snapshot) renderFoveated(result.snapshot);
    if (result && result.status === 'nothingToStop') {
      setFovOpMsg('Nothing left to stop.', null);
    } else {
      /* The backend reports what it actually managed, including partial failures — stopping a
         service needs rights the backend does not have, so "could not stop Sunshine" is a normal
         outcome and has to reach the user rather than being swallowed into a success. */
      setFovOpMsg(result?.detail || 'Done.', null);
    }
  } catch (e) {
    setFovOpMsg('Could not stop them: ' + e.message, 'error');
  } finally {
    el.fovConflictBtn.disabled = false;
    el.fovConflictBtn.textContent = label;
    await refreshFoveatedStatus();
  }
}

async function onPcvrAction() {
  if (pcvrActive()) {
    await stopPcvr();
    return;
  }

  if (fovMode() === 'tailnet' && (!tsInfo.selfIp || tsInfo.backendState !== 'Running')) {
    setFovOpMsg('Tailscale is not running or has no IPv4 address. Use Local network or start Tailscale.', 'error');
    el.pcvrOptions.open = true;
    return;
  }

  pcvrBusy = true;
  pcvrBusyOp = 'start';
  setFovOpMsg('Preparing the PCVR host…');
  renderPcvrSummary();
  try {
    if (el.pcvrServices.checked) {
      const result = await window.hotspot.startPcvrStack(pcvrStartParams());
      const failed = (result.steps || []).find((step) => !step.ok);
      if (!result.ok) {
        throw new Error((failed && `${failed.step}: ${failed.detail || 'failed'}`) || 'PCVR services failed to start.');
      }
      setFovOpMsg(failed
        ? `PCVR is ready, but ${failed.step} is unavailable${failed.detail ? `: ${failed.detail}` : '.'}`
        : 'PCVR is ready.', failed ? 'error' : 'ok');
    } else {
      const result = await window.hotspot.foveatedStart(pcvrStartParams());
      if (!result.ok) throw new Error(result.detail || result.status || 'The host failed to start.');
      if (result.snapshot) renderFoveated(result.snapshot);
      setFovOpMsg('PCVR host is ready.', 'ok');
    }
  } catch (err) {
    setFovOpMsg(`Could not start PCVR: ${err.message || err}`, 'error');
  } finally {
    pcvrBusy = false;
    pcvrBusyOp = null;
    lastServices = await window.hotspot.servicesStatus();
    try { renderFoveated(await window.hotspot.foveatedStatus()); } catch { renderPcvrSummary(); }
    renderServices(lastServices);
  }
}

/**
 * Passthrough cutouts, switched with a running PCVR.
 *
 * Both halves of the switch — the yaml's alpha channel and the broker's blend mode — are
 * read once at start, so the only honest way to change it live is to take the stack down
 * and bring it back up. That is done here rather than in the host because the safe order
 * is a full stop and start: bouncing CloudXR under a live broker is the failure this
 * codebase keeps warning about, and the stack scripts already sequence it correctly.
 *
 * The stop path asks before killing a running game, and a declined confirmation puts the
 * switch back — a control that silently did nothing would be worse than one that reverts.
 */
async function onPassthroughToggled() {
  savePcvrOptions();
  if (!pcvrActive()) return;
  const wanted = el.fovPassthrough.value === 'on';
  setFovOpMsg(`Restarting PCVR to turn passthrough cutouts ${wanted ? 'on' : 'off'}…`);
  const stopped = await stopPcvr();
  if (!stopped) {
    el.fovPassthrough.value = wanted ? 'off' : 'on';
    savePcvrOptions();
    return;
  }
  await onPcvrAction();
}

/** Returns whether PCVR actually stopped, so a caller restarting it can tell. */
async function stopPcvr() {
  // Confirm only when stopping would kill a running game. An idle session (the
  // "OpenXR app" being merely the broker) stops with one click.
  if (lastFoveated?.titleRunning && !await window.hotspot.confirmPcvrStop()) return false;
  pcvrBusy = true;
  pcvrBusyOp = 'stop';
  setFovOpMsg('Stopping PCVR…');
  renderPcvrSummary();
  let stopped = false;
  try {
    const result = await window.hotspot.stopPcvrStack();
    if (!result?.ok) throw new Error(result?.detail || 'PCVR stopped with an unknown error.');
    setFovOpMsg('PCVR stopped.', 'ok');
    stopped = true;
  } catch (err) {
    setFovOpMsg(`Could not stop PCVR: ${err.message || err}`, 'error');
  } finally {
    pcvrBusy = false;
    pcvrBusyOp = null;
    lastServices = await window.hotspot.servicesStatus();
    try { renderFoveated(await window.hotspot.foveatedStatus()); } catch { renderPcvrSummary(); }
    renderServices(lastServices);
  }
  return stopped;
}

const PCVR_OPTIONS_KEY = 'longwave.pcvr.options.v1';

function restorePcvrOptions() {
  let saved;
  try { saved = JSON.parse(localStorage.getItem(PCVR_OPTIONS_KEY) || '{}'); } catch { saved = {}; }
  if (typeof saved.services === 'boolean') el.pcvrServices.checked = saved.services;
  if (typeof saved.desktopQuad === 'boolean') el.pcvrDesktop.checked = saved.desktopQuad;
  if (['lan', 'tailnet'].includes(saved.mode)) el.fovModeSelect.value = saved.mode;
  if (['performance', 'balanced', 'quality'].includes(saved.quality)) el.fovQuality.value = saved.quality;
  if (['on', 'off'].includes(saved.vrchatOsc)) el.fovVrchatOsc.value = saved.vrchatOsc;
  if (['on', 'off'].includes(saved.passthrough)) el.fovPassthrough.value = saved.passthrough;
  // Edition select, formerly a free-text bundle id. Only the two editions are
  // valid; anything else saved by an older build (e.g. the stale "pro.longwave"
  // default that made discovery invisible to both real apps) resets to App Store.
  if (['pro.longwave.app', 'pro.longwave.oss'].includes(saved.bundleId)) {
    el.fovBundleId.value = saved.bundleId;
  }
  if (Number.isInteger(saved.port) && saved.port > 0 && saved.port <= 65535) el.fovPort.value = String(saved.port);
  if (typeof saved.lanIpAddress === 'string') lanAdvertiseIp = saved.lanIpAddress;
  if (el.fovModeSelect.value === 'lan') el.fovIp.value = lanAdvertiseIp;
  if (typeof saved.forceQr === 'boolean') el.fovForceQr.checked = saved.forceQr;
}

function savePcvrOptions() {
  const port = parseInt(el.fovPort.value, 10);
  localStorage.setItem(PCVR_OPTIONS_KEY, JSON.stringify({
    services: el.pcvrServices.checked,
    desktopQuad: el.pcvrDesktop.checked,
    mode: fovMode(),
    quality: el.fovQuality.value,
    vrchatOsc: el.fovVrchatOsc.value,
    passthrough: el.fovPassthrough.value,
    bundleId: el.fovBundleId.value.trim(),
    port: Number.isFinite(port) ? port : 55000,
    lanIpAddress: fovMode() === 'lan' ? el.fovIp.value.trim() : lanAdvertiseIp,
    forceQr: el.fovForceQr.checked,
  }));
}

/* ------------------------------------------------------------------ */
/* Games — curation happens here, not on the headset                   */

/* The full library, each entry flagged `exposed`. Kept in memory because the filter box must never
   change what is exposed: GamesSetExposed replaces the whole set, so a toggle has to submit every
   exposed id including the ones currently filtered out of view. */
let gamesCache = [];

function gamesSetMsg(text, isError) {
  el.gamesOpMsg.textContent = text || '';
  el.gamesOpMsg.classList.toggle('is-fault', Boolean(isError));
}

async function refreshGames() {
  if (!hasPcvr) { renderGames(); return; }
  try {
    gamesCache = (await window.hotspot.gamesList()) || [];
    gamesSetMsg('');
  } catch (err) {
    gamesCache = [];
    // "Not connected yet" is a different situation from "the library could not be read",
    // and only one of them is worth worrying about: this one clears itself.
    const message = String(err && err.message ? err.message : err);
    gamesSetMsg(message.includes('not connected')
      ? 'Waiting for the backend — the list will load by itself.'
      : `Could not read the library: ${message}`, !message.includes('not connected'));
  }
  renderGames();
}

/* Art is fetched per tile after the grid is in the DOM, not before it. Loading 29 base64 images up
   front would stall the first paint for no reason; this way the tiles appear immediately with their
   placeholder and fill in. */
async function loadTileArt(tile, title) {
  if (!title.landscapeArt) return;
  try {
    const url = await window.hotspot.gameArt(title.landscapeArt);
    if (!url) return;
    // The grid may have been re-rendered (filter typed, toggle saved) while this was in flight.
    if (!tile.isConnected) return;
    const img = document.createElement('img');
    img.className = 'game-tile-art';
    img.alt = '';
    /* has-art hides the placeholder, so only set it once the image has actually decoded —
       otherwise a corrupt cover would hide the placeholder and leave an empty tile. */
    img.addEventListener('load', () => tile.classList.add('has-art'));
    img.addEventListener('error', () => img.remove());
    img.src = url;
    tile.insertBefore(img, tile.firstChild);
  } catch {
    /* Placeholder stays; a missing cover is not worth a message. */
  }
}

function renderGames() {
  el.gamesFilter.disabled = !hasPcvr;
  el.gamesAddBtn.disabled = !hasPcvr;
  el.gamesRefreshBtn.disabled = !hasPcvr;
  if (!hasPcvr) {
    el.gamesCount.textContent = '—';
    el.gamesList.textContent = '';
    const empty = document.createElement('div');
    empty.className = 'games-empty';
    empty.textContent = 'PCVR isn’t installed. Download it from the PCVR tab to see your library here.';
    el.gamesList.appendChild(empty);
    return;
  }

  const filter = el.gamesFilter.value.trim().toLowerCase();
  const visible = filter
    ? gamesCache.filter((t) => (t.name || '').toLowerCase().includes(filter))
    : gamesCache;

  const exposedCount = gamesCache.filter((t) => t.exposed).length;
  el.gamesCount.textContent =
    `${exposedCount} of ${gamesCache.length} available to the headset` +
    (filter ? ` · showing ${visible.length}` : '');

  el.gamesList.textContent = '';
  if (visible.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'games-empty';
    empty.textContent = gamesCache.length === 0
      ? 'No titles found. Is Steam installed? You can still add a game manually.'
      : 'Nothing matches that filter.';
    el.gamesList.appendChild(empty);
    return;
  }

  for (const title of visible) {
    const tile = document.createElement('label');
    tile.className = 'game-tile' + (title.exposed ? ' selected' : '');

    /* Under the art, so a title with no cover still reads as a tile rather than a blank box. */
    const placeholder = document.createElement('div');
    placeholder.className = 'game-tile-placeholder';
    placeholder.textContent = (title.name || '?').trim().charAt(0).toUpperCase();
    tile.appendChild(placeholder);

    const check = document.createElement('input');
    check.type = 'checkbox';
    check.className = 'game-tile-check';
    check.checked = Boolean(title.exposed);
    check.addEventListener('change', () => onToggleExposed(title, check, tile));
    tile.appendChild(check);

    const caption = document.createElement('div');
    caption.className = 'game-tile-caption';
    const name = document.createElement('div');
    name.className = 'game-tile-name';
    name.textContent = title.name || title.id;
    name.title = title.source === 'steam' ? `Steam ${title.steamAppId}` : (title.executable || '');
    caption.appendChild(name);
    tile.appendChild(caption);

    const actions = document.createElement('div');
    actions.className = 'game-tile-actions';
    /* Launching from here checks a title works before trusting it to the headset — same code path,
       minus the headset. */
    const launch = document.createElement('button');
    launch.className = 'game-tile-btn';
    launch.textContent = 'Launch';
    launch.title = 'Launch on this PC';
    launch.addEventListener('click', (e) => { e.preventDefault(); onLaunchGame(title); });
    actions.appendChild(launch);
    if (title.source === 'custom') {
      const remove = document.createElement('button');
      remove.className = 'game-tile-btn';
      remove.textContent = 'Remove';
      remove.addEventListener('click', (e) => { e.preventDefault(); onRemoveGame(title); });
      actions.appendChild(remove);
    }
    /* Titles with a curated launch profile get a per-title toggle. Off = completely stock
       launch; the tooltip carries the backend's explanation of what the profile changes. */
    if (title.optimizedAvailable) {
      const opt = document.createElement('button');
      opt.className = 'game-tile-btn game-tile-opt' + (title.optimized ? ' on' : '');
      opt.textContent = title.optimized ? 'Optimized ✓' : 'Optimized';
      opt.title = title.optimizedNote || 'Launch with settings tuned for this host.';
      opt.addEventListener('click', (e) => { e.preventDefault(); onToggleOptimized(title, opt); });
      actions.appendChild(opt);
    }
    tile.appendChild(actions);

    el.gamesList.appendChild(tile);
    loadTileArt(tile, title);
  }
}

async function onToggleOptimized(title, button) {
  const wanted = !title.optimized;
  button.disabled = true;
  try {
    const updated = await window.hotspot.gamesSetOptimized(title.id, wanted);
    if (updated) {
      const byId = new Map(updated.map((t) => [t.id, t.optimized]));
      for (const t of gamesCache) if (byId.has(t.id)) t.optimized = byId.get(t.id);
    } else {
      title.optimized = wanted;
    }
    gamesSetMsg('');
  } catch (err) {
    gamesSetMsg(`Could not save: ${err.message || err}`);
  }
  button.disabled = false;
  button.classList.toggle('on', title.optimized);
  button.textContent = title.optimized ? 'Optimized ✓' : 'Optimized';
}

async function onToggleExposed(title, check, tile) {
  const previous = title.exposed;
  title.exposed = check.checked;
  /* Highlight immediately so the click feels answered, then reconcile below if the save fails. */
  if (tile) tile.classList.toggle('selected', title.exposed);

  const ids = gamesCache.filter((t) => t.exposed).map((t) => t.id);
  try {
    const updated = await window.hotspot.gamesSetExposed(ids);
    if (updated) {
      /* Merge exposure rather than replacing the cache: the response has no art field resolved
         differently, but re-rendering from it would drop the art already loaded into tiles. */
      const byId = new Map(updated.map((t) => [t.id, t.exposed]));
      for (const t of gamesCache) if (byId.has(t.id)) t.exposed = byId.get(t.id);
    }
    gamesSetMsg('');
    syncTileSelection();
  } catch (err) {
    title.exposed = previous;
    check.checked = previous;
    if (tile) tile.classList.toggle('selected', previous);
    gamesSetMsg(`Could not save: ${err.message || err}`, true);
  }
  updateGamesCount();
}

/* Reflect the model onto the existing tiles without rebuilding them, so loaded art survives. */
function syncTileSelection() {
  const tiles = el.gamesList.querySelectorAll('.game-tile');
  const filter = el.gamesFilter.value.trim().toLowerCase();
  const visible = filter
    ? gamesCache.filter((t) => (t.name || '').toLowerCase().includes(filter))
    : gamesCache;
  tiles.forEach((tile, i) => {
    const title = visible[i];
    if (!title) return;
    tile.classList.toggle('selected', Boolean(title.exposed));
    const box = tile.querySelector('.game-tile-check');
    if (box) box.checked = Boolean(title.exposed);
  });
}

function updateGamesCount() {
  const filter = el.gamesFilter.value.trim().toLowerCase();
  const shown = filter
    ? gamesCache.filter((t) => (t.name || '').toLowerCase().includes(filter)).length
    : gamesCache.length;
  const exposedCount = gamesCache.filter((t) => t.exposed).length;
  el.gamesCount.textContent =
    `${exposedCount} of ${gamesCache.length} available to the headset` +
    (filter ? ` · showing ${shown}` : '');
}

async function onAddGame() {
  let picked;
  try {
    picked = await window.hotspot.pickExecutable();
  } catch (err) {
    gamesSetMsg(`Could not open the file picker: ${err.message || err}`, true);
    return;
  }
  if (!picked) return; // cancelled

  try {
    gamesCache = (await window.hotspot.gamesAddCustom({ path: picked })) || gamesCache;
    gamesSetMsg(`Added ${picked}`);
  } catch (err) {
    gamesSetMsg(`Could not add that file: ${err.message || err}`, true);
  }
  renderGames();
}

async function onRemoveGame(title) {
  try {
    await window.hotspot.gamesRemoveCustom(title.id);
    await refreshGames();
    gamesSetMsg(`Removed ${title.name}`);
  } catch (err) {
    gamesSetMsg(`Could not remove: ${err.message || err}`, true);
  }
}

async function onLaunchGame(title) {
  gamesSetMsg(`Launching ${title.name}…`);
  try {
    const ok = await window.hotspot.gamesLaunch(title.id);
    gamesSetMsg(ok ? `Launched ${title.name}.` : `The host refused to launch ${title.name}.`, !ok);
  } catch (err) {
    gamesSetMsg(`Launch failed: ${err.message || err}`, true);
  }
}

/* ------------------------------------------------------------------ */
/* PCVR services — supervised by this app, not by Task Scheduler       */

/* Rendered from the supervisor's own view of its children rather than from a process scan:
   anything we did not start we also cannot stop.

   The question asked of each service is `healthy`, not "is the process alive". Gaze fix
   patches the running CloudXR process and exits, so a clean exit is exactly what success
   looks like — judging it by liveness reported a perfectly good stack as PARTIAL with
   "gaze fix stopped", which reads as a fault and sent the user looking for one. */
function renderServices(status) {
  if (!status) return;
  lastServices = status;
  const names = Object.keys(status);

  el.svcList.innerHTML = '';
  for (const name of names) {
    const service = status[name];
    const span = document.createElement('span');
    span.innerHTML = `${service.title}: <strong></strong>`;
    span.querySelector('strong').textContent = describeService(service);
    el.svcList.appendChild(span);
  }
  renderPcvrSummary();
}

function describeService(service) {
  if (!service.exe) return 'not built';
  if (service.running) {
    return `pid ${service.pid}` + (service.restarts ? ` (restarted ${service.restarts}×)` : '');
  }
  if (service.oneShot) {
    if (service.completed) return 'hook installed';
    if (service.lastExitCode !== null) return `failed (code ${service.lastExitCode})`;
    return 'not run';
  }
  return service.lastExitCode !== null ? `stopped (code ${service.lastExitCode})` : 'stopped';
}

// ── Wiring ─────────────────────────────────────────────────────────────────

window.addEventListener('DOMContentLoaded', async () => {
  hasPcvr = typeof window.hotspot.pcvrAvailable === 'function'
    && await window.hotspot.pcvrAvailable();
  // Live updates for the common case (the host process exits/crashes mid-session); a host
  // that appears for the first time after load still needs a relaunch to pick up its polling
  // intervals below, which is an acceptable gap for a component installed once at setup time.
  if (typeof window.hotspot.onPcvrConnection === 'function') {
    window.hotspot.onPcvrConnection((connected) => {
      hasPcvr = connected;
      applyHostCapabilities();
    });
  }

  for (const tab of document.querySelectorAll('.channel')) {
    tab.addEventListener('click', () => showView(tab.dataset.view));
  }
  for (const button of document.querySelectorAll('[data-copy]')) {
    button.addEventListener('click', () => copyReadout(button.dataset.copy));
  }

  el.nsStartBtn.addEventListener('click', async () => {
    renderNativeStream(await window.hotspot.nativeStreamSetEnabled(true));
    toast('Streaming started');
  });
  el.nsStopBtn.addEventListener('click', async () => {
    renderNativeStream(await window.hotspot.nativeStreamSetEnabled(false));
    toast('Streaming stopped');
  });
  el.nsMouse.addEventListener('change', async () => {
    renderNativeStream(await window.hotspot.nativeStreamSetInput({ mouse: el.nsMouse.checked }));
  });
  el.nsKeyboard.addEventListener('change', async () => {
    renderNativeStream(await window.hotspot.nativeStreamSetInput({ keyboard: el.nsKeyboard.checked }));
  });
  el.nsRegenToken.addEventListener('click', async () => {
    renderNativeStream(await window.hotspot.nativeStreamRegenerateToken());
    toast('New token — reconnect the headset with it');
  });
  el.nsAddressPick.addEventListener('change', () => {
    preferredAddress = el.nsAddressPick.value;
    setReadout(el.nsHost, preferredAddress);
  });

  el.startBtn.addEventListener('click', onStart);
  el.stopBtn.addEventListener('click', onStop);
  el.fixAdapterBtn.addEventListener('click', onFixAdapter);
  el.regen.addEventListener('click', async () => {
    el.passphrase.value = await window.hotspot.genPassphrase();
  });

  applyHostCapabilities();

  el.pcvrDlBtn.addEventListener('click', onDownloadPcvr);
  if (typeof window.hotspot.onPcvrDownloadProgress === 'function') {
    window.hotspot.onPcvrDownloadProgress(onPcvrDownloadProgress);
  }

  el.pcvrActionBtn.addEventListener('click', onPcvrAction);
  el.fovShowPairingBtn.addEventListener('click', () => window.hotspot.openPairingWindow());
  el.noticesBtn.addEventListener('click', () => window.hotspot.openNoticesWindow());
  el.fovConflictBtn.addEventListener('click', onStopConflicts);
  for (const control of [
    el.pcvrServices, el.fovModeSelect, el.fovQuality, el.fovVrchatOsc,
    el.fovBundleId, el.fovPort, el.fovIp, el.fovForceQr,
  ]) {
    control.addEventListener('change', () => {
      savePcvrOptions();
      applyMode();
      refreshPath();
    });
  }
  el.pcvrDesktop.addEventListener('change', onDesktopQuadToggled);
  el.fovPassthrough.addEventListener('change', onPassthroughToggled);

  el.gamesFilter.addEventListener('input', renderGames);
  el.gamesRefreshBtn.addEventListener('click', refreshGames);
  el.gamesAddBtn.addEventListener('click', onAddGame);

  el.ssid.value = await window.hotspot.genSsid();
  el.passphrase.value = await window.hotspot.genPassphrase();
  restorePcvrOptions();

  if (hasPcvr) {
    // Tailscale node status + the DERP path watchdog.
    refreshTailscale();
    setInterval(refreshTailscale, 5000);
    setInterval(refreshPath, 10000);
    setInterval(refreshFoveatedStatus, 5000);

    window.hotspot.onServices(renderServices);
    lastServices = await window.hotspot.servicesStatus();
    renderServices(lastServices);
  }

  window.hotspot.onConnection(setBackendConnected);
  window.hotspot.onNotify(({ event, data }) => {
    if (event === 'state') renderStatus(data);
    else if (event === 'foveated') renderFoveated(data);
    else if (event === 'nativeStream') renderNativeStream(data);
  });

  setBackendConnected(await window.hotspot.isConnected());
});
