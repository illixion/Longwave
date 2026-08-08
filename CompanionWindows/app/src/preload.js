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

  // Native screen streaming (VisionVNC "Native" protocol on port 4857).
  nativeStreamStatus: () => ipcRenderer.invoke('rpc', 'NativeStreamStatus'),
  nativeStreamSetEnabled: (enabled) => ipcRenderer.invoke('rpc', 'NativeStreamSetEnabled', { enabled }),
  nativeStreamSetInput: (params) => ipcRenderer.invoke('rpc', 'NativeStreamSetInput', params),
  nativeStreamRegenerateToken: () => ipcRenderer.invoke('rpc', 'NativeStreamRegenerateToken'),

  // Local helpers (no backend round-trip).
  genPassphrase: () => ipcRenderer.invoke('gen-passphrase'),
  genSsid: () => ipcRenderer.invoke('gen-ssid'),
  isConnected: () => ipcRenderer.invoke('get-connection'),

  // Subscriptions. Return an unsubscribe fn.
  onConnection: (cb) => {
    const h = (_e, connected) => cb(connected);
    ipcRenderer.on('connection', h);
    return () => ipcRenderer.removeListener('connection', h);
  },
  onNotify: (cb) => {
    const h = (_e, payload) => cb(payload);
    ipcRenderer.on('notify', h);
    return () => ipcRenderer.removeListener('notify', h);
  },
});
