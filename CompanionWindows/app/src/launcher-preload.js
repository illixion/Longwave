'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// The Launch game picker's whole surface. It names things by id or recents key only — no path
// ever goes from this window to the main process, so the picker cannot be used to start an
// arbitrary file; Browse opens the native dialog in the main process instead.
contextBridge.exposeInMainWorld('launcher', {
  getState: () => ipcRenderer.invoke('launcher-state'),
  launchTitle: (id) => ipcRenderer.invoke('launcher-launch-title', id),
  launchRecent: (key) => ipcRenderer.invoke('launcher-launch-recent', key),
  browse: () => ipcRenderer.invoke('launcher-browse'),
  setAskBeforeLaunch: (ask) => ipcRenderer.invoke('launcher-set-ask', ask),
  createShortcut: (key) => ipcRenderer.invoke('launcher-create-shortcut', key),
  close: () => ipcRenderer.invoke('launcher-close'),
  onMode: (cb) => {
    const handler = (_event, state) => cb(state);
    ipcRenderer.on('launcher-mode', handler);
    return () => ipcRenderer.removeListener('launcher-mode', handler);
  },
  onRefresh: (cb) => {
    const handler = () => cb();
    ipcRenderer.on('launcher-refresh', handler);
    return () => ipcRenderer.removeListener('launcher-refresh', handler);
  },
});
