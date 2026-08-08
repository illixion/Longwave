'use strict';
const $ = (id) => document.getElementById(id);

const el = {
  backendPill: $('backendPill'),
  capabilityBanner: $('capabilityBanner'),
  stateBadge: $('stateBadge'),
  ssid: $('ssid'),
  passphrase: $('passphrase'),
  band: $('band'),
  upstream: $('upstream'),
  startBtn: $('startBtn'),
  stopBtn: $('stopBtn'),
  fixAdapterBtn: $('fixAdapterBtn'),
  regen: $('regen'),
  opMsg: $('opMsg'),
  nsBadge: $('nsBadge'),
  nsToken: $('nsToken'),
  nsCopyToken: $('nsCopyToken'),
  nsRegenToken: $('nsRegenToken'),
  nsPort: $('nsPort'),
  nsStartBtn: $('nsStartBtn'),
  nsStopBtn: $('nsStopBtn'),
  nsMouse: $('nsMouse'),
  nsKeyboard: $('nsKeyboard'),
  nsMsg: $('nsMsg'),
  nsViewer: $('nsViewer'),
  joinPanel: $('joinPanel'),
  joinSsid: $('joinSsid'),
  joinPass: $('joinPass'),
  joinGateway: $('joinGateway'),
  clientCount: $('clientCount'),
  maxClients: $('maxClients'),
  upstreamName: $('upstreamName'),
};

let lastState = 'off';

function setBackendConnected(connected) {
  el.backendPill.textContent = connected ? 'Backend: connected' : 'Backend: disconnected';
  el.backendPill.className = 'pill ' + (connected ? 'pill-good' : 'pill-bad');
  el.startBtn.disabled = !connected;
  if (connected) refreshAll();
}

function setOpMsg(text, kind) {
  el.opMsg.textContent = text || '';
  el.opMsg.className = 'op-msg' + (kind ? ' ' + kind : '');
}

function renderStatus(s) {
  if (!s) return;
  lastState = s.state;

  // State badge
  const map = {
    on: ['ON', 'badge-on'],
    off: ['OFF', 'badge-off'],
    inTransition: ['…', 'badge-transition'],
    unknown: ['?', 'badge-off'],
  };
  const [label, cls] = map[s.state] || map.unknown;
  el.stateBadge.textContent = label;
  el.stateBadge.className = 'badge ' + cls;

  // Start/Stop visibility
  const on = s.state === 'on';
  el.startBtn.classList.toggle('hidden', on);
  el.stopBtn.classList.toggle('hidden', !on);

  // Capability banner
  if (s.canHostAp === false) {
    el.capabilityBanner.classList.remove('hidden');
    el.capabilityBanner.textContent = '⚠ ' + (s.capabilityDetail || 'This PC may not be able to host a Wi-Fi hotspot.');
  } else {
    el.capabilityBanner.classList.add('hidden');
  }

  // Join panel
  el.joinPanel.classList.toggle('hidden', !on);
  if (on) {
    el.joinSsid.textContent = s.ssid || '—';
    el.joinPass.textContent = s.passphrase || '—';
    el.joinGateway.textContent = s.gatewayIp || '192.168.137.1';
    el.clientCount.textContent = s.clientCount ?? 0;
    el.maxClients.textContent = s.maxClientCount ?? '—';
    el.upstreamName.textContent = s.upstreamName || '—';
  }
}

function renderNativeStream(s) {
  if (!s) return;
  const running = !!s.running;
  el.nsBadge.textContent = running ? 'ON' : 'OFF';
  el.nsBadge.className = 'badge ' + (running ? 'badge-on' : 'badge-off');
  el.nsStartBtn.classList.toggle('hidden', running);
  el.nsStopBtn.classList.toggle('hidden', !running);
  el.nsToken.value = s.token || '';
  el.nsPort.value = s.port || 4857;
  el.nsMouse.checked = !!s.mouseControlEnabled;
  el.nsKeyboard.checked = !!s.keyboardControlEnabled;
  if (s.lastError) {
    el.nsMsg.textContent = s.lastError;
    el.nsMsg.className = 'op-msg error';
  } else if (!s.captureSupported) {
    el.nsMsg.textContent = 'Screen capture is not supported on this Windows build.';
    el.nsMsg.className = 'op-msg error';
  }
  el.nsViewer.textContent = s.connectedDevice
    ? `Streaming to ${s.connectedDevice}`
    : (running ? 'Waiting for a viewer…' : '');
}

async function refreshNativeStream() {
  try {
    renderNativeStream(await window.hotspot.nativeStreamStatus());
  } catch (e) {
    el.nsMsg.textContent = 'Could not read streaming status: ' + e.message;
    el.nsMsg.className = 'op-msg error';
  }
}

async function refreshAll() {
  try {
    await loadUpstreams();
    await refreshNativeStream();
    const s = await window.hotspot.getStatus();
    // Seed SSID/pass fields from the live AP if running; else keep generated defaults.
    if (s.state === 'on') {
      if (s.ssid) el.ssid.value = s.ssid;
      if (s.passphrase) el.passphrase.value = s.passphrase;
      if (s.band) el.band.value = s.band;
    }
    renderStatus(s);
  } catch (e) {
    setOpMsg('Could not read status: ' + e.message, 'error');
  }
}

async function loadUpstreams() {
  try {
    const list = await window.hotspot.listUpstreams();
    const prev = el.upstream.value;
    el.upstream.innerHTML = '';
    for (const p of list) {
      const opt = document.createElement('option');
      opt.value = p.id;
      const tag = p.kind === 'ethernet' ? 'Ethernet' : p.kind === 'wifi' ? 'Wi-Fi' : p.kind;
      opt.textContent = `${p.name} (${tag})${p.isDefault ? ' • default' : ''}${p.hasInternet ? '' : ' • no internet'}`;
      if (p.tetheringCapability !== 'enabled') opt.textContent += ` • ${p.tetheringCapability}`;
      el.upstream.appendChild(opt);
    }
    // Restore previous selection or pick the default.
    const def = list.find((p) => p.isDefault);
    el.upstream.value = list.some((p) => p.id === prev) ? prev : (def ? def.id : (list[0] && list[0].id));
  } catch (e) {
    setOpMsg('Could not list upstreams: ' + e.message, 'error');
  }
}

async function onStart() {
  setOpMsg('Starting…');
  el.startBtn.disabled = true;
  try {
    const params = {
      ssid: el.ssid.value.trim() || undefined,
      passphrase: el.passphrase.value.trim() || undefined,
      band: el.band.value,
      profileId: el.upstream.value || undefined,
    };
    const res = await window.hotspot.start(params);
    if (res.ok) {
      setOpMsg('Hotspot started.', 'ok');
      el.fixAdapterBtn.classList.add('hidden');
      renderStatus(res.snapshot);
    } else {
      setOpMsg(`Failed (${res.status}): ${res.detail || ''}`, 'error');
      // Offer the guided fix when an incapable adapter is blocking a capable one.
      el.fixAdapterBtn.classList.toggle('hidden', res.status !== 'adapterConflict');
      renderStatus(res.snapshot);
    }
  } catch (e) {
    setOpMsg('Start error: ' + e.message, 'error');
  } finally {
    el.startBtn.disabled = !(await window.hotspot.isConnected());
  }
}

async function onFixAdapter() {
  setOpMsg('Disabling conflicting adapter…');
  el.fixAdapterBtn.disabled = true;
  try {
    const r = await window.hotspot.prepareApAdapter();
    if (!r.ok) {
      setOpMsg(r.detail || 'Could not prepare an adapter.', 'error');
      return;
    }
    setOpMsg(r.detail || 'Adapter disabled; retrying…', 'ok');
    el.fixAdapterBtn.classList.add('hidden');
    await onStart(); // retry now that the capable radio is the only Wi-Fi adapter
  } catch (e) {
    setOpMsg('Fix error: ' + e.message, 'error');
  } finally {
    el.fixAdapterBtn.disabled = false;
  }
}

async function onStop() {
  setOpMsg('Stopping…');
  el.stopBtn.disabled = true;
  try {
    const res = await window.hotspot.stop();
    setOpMsg(res.ok ? 'Hotspot stopped.' : `Stop failed: ${res.detail || res.status}`, res.ok ? 'ok' : 'error');
    if (res.snapshot) renderStatus(res.snapshot);
  } catch (e) {
    setOpMsg('Stop error: ' + e.message, 'error');
  } finally {
    el.stopBtn.disabled = false;
  }
}

async function copyValue(id) {
  const text = $(id).textContent;
  try {
    await navigator.clipboard.writeText(text);
    setOpMsg(`Copied ${text}`, 'ok');
  } catch {
    setOpMsg('Copy failed', 'error');
  }
}

// ---- wire up ----
window.addEventListener('DOMContentLoaded', async () => {
  el.ssid.value = await window.hotspot.genSsid();
  el.passphrase.value = await window.hotspot.genPassphrase();

  el.startBtn.addEventListener('click', onStart);
  el.stopBtn.addEventListener('click', onStop);
  el.fixAdapterBtn.addEventListener('click', onFixAdapter);
  el.regen.addEventListener('click', async () => { el.passphrase.value = await window.hotspot.genPassphrase(); });
  document.querySelectorAll('.copy').forEach((b) =>
    b.addEventListener('click', () => copyValue(b.dataset.copy)));

  el.nsStartBtn.addEventListener('click', async () => {
    renderNativeStream(await window.hotspot.nativeStreamSetEnabled(true));
  });
  el.nsStopBtn.addEventListener('click', async () => {
    renderNativeStream(await window.hotspot.nativeStreamSetEnabled(false));
  });
  el.nsMouse.addEventListener('change', async () => {
    renderNativeStream(await window.hotspot.nativeStreamSetInput({ mouse: el.nsMouse.checked }));
  });
  el.nsKeyboard.addEventListener('change', async () => {
    renderNativeStream(await window.hotspot.nativeStreamSetInput({ keyboard: el.nsKeyboard.checked }));
  });
  el.nsCopyToken.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(el.nsToken.value);
      setOpMsg('Token copied', 'ok');
    } catch {
      setOpMsg('Copy failed', 'error');
    }
  });
  el.nsRegenToken.addEventListener('click', async () => {
    renderNativeStream(await window.hotspot.nativeStreamRegenerateToken());
  });

  window.hotspot.onConnection(setBackendConnected);
  window.hotspot.onNotify(({ event, data }) => {
    if (event === 'state') renderStatus(data);
    if (event === 'nativeStream') renderNativeStream(data);
  });

  setBackendConnected(await window.hotspot.isConnected());
});
