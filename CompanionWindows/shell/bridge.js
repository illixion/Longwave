'use strict';
// Injected into every document before page scripts run. Reproduces exactly the surface
// the Electron preload exposed via contextBridge, so the renderer is unchanged: promises
// over chrome.webview.postMessage instead of ipcRenderer.invoke.
(() => {
  const pending = new Map();
  const listeners = { connection: new Set(), notify: new Set() };
  let nextId = 1;

  chrome.webview.addEventListener('message', (e) => {
    const msg = e.data;
    if (!msg) return;

    if (msg.event) {
      const set = listeners[msg.event];
      if (set) for (const cb of set) cb(msg.data);
      return;
    }

    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    if (msg.error) p.reject(new Error(msg.error));
    else p.resolve(msg.result);
  });

  function call(channel, method, params) {
    return new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      chrome.webview.postMessage({ id, channel, method, params });
    });
  }

  const rpc = (method, params) => call('rpc', method, params);
  const local = (method) => call('local', method);

  function subscribe(name, cb) {
    listeners[name].add(cb);
    return () => listeners[name].delete(cb);
  }

  window.hotspot = {
    // RPC to the backend.
    getStatus: () => rpc('GetStatus'),
    listUpstreams: () => rpc('ListUpstreamProfiles'),
    start: (params) => rpc('StartHotspot', params),
    stop: () => rpc('StopHotspot'),
    listWifiAdapters: () => rpc('ListWifiAdapters'),
    prepareApAdapter: () => rpc('PrepareApAdapter'),

    // Native screen streaming (Longwave "Native" protocol on port 4857).
    nativeStreamStatus: () => rpc('NativeStreamStatus'),
    nativeStreamSetEnabled: (enabled) => rpc('NativeStreamSetEnabled', { enabled }),
    nativeStreamSetInput: (params) => rpc('NativeStreamSetInput', params),
    nativeStreamRegenerateToken: () => rpc('NativeStreamRegenerateToken'),

    // Local helpers (no backend round-trip).
    genPassphrase: () => local('gen-passphrase'),
    genSsid: () => local('gen-ssid'),
    isConnected: () => local('get-connection'),

    // Subscriptions. Return an unsubscribe fn.
    onConnection: (cb) => subscribe('connection', cb),
    onNotify: (cb) => subscribe('notify', cb),
  };
})();
