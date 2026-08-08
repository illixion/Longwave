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

function showView(viewId) {
  for (const tab of document.querySelectorAll('.channel')) {
    const current = tab.dataset.view === viewId;
    tab.classList.toggle('is-current', current);
    tab.setAttribute('aria-selected', String(current));
    $(tab.dataset.view).classList.toggle('hidden', !current);
  }
}

// ── Backend connection ─────────────────────────────────────────────────────

function setBackendConnected(connected) {
  setLamp(el.backendLamp, connected ? 'live' : 'fault');
  el.backendText.textContent = connected
    ? 'Companion service running'
    : 'Companion service unreachable';
  el.startBtn.disabled = !connected;
  el.nsStartBtn.disabled = !connected;
  if (connected) refreshAll();
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
    el.nsViewer.textContent = 'Add a Native connection in VisionVNC using the details below.';
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

// ── Wiring ─────────────────────────────────────────────────────────────────

window.addEventListener('DOMContentLoaded', async () => {
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

  el.ssid.value = await window.hotspot.genSsid();
  el.passphrase.value = await window.hotspot.genPassphrase();

  window.hotspot.onConnection(setBackendConnected);
  window.hotspot.onNotify(({ event, data }) => {
    if (event === 'state') renderStatus(data);
    if (event === 'nativeStream') renderNativeStream(data);
  });

  setBackendConnected(await window.hotspot.isConnected());
});
