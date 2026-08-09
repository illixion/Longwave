'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('pairing', {
  toggleReveal: () => ipcRenderer.invoke('pairing-toggle-reveal'),
  onState: (cb) => {
    const handler = (_event, state) => cb(state);
    ipcRenderer.on('pairing-state', handler);
    return () => ipcRenderer.removeListener('pairing-state', handler);
  },
});
