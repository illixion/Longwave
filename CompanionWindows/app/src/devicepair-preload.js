'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('devicePairing', {
  answer: (id, approve, grants) => ipcRenderer.invoke('device-pairing-answer', { id, approve, grants }),
  onState: (cb) => {
    const handler = (_event, state) => cb(state);
    ipcRenderer.on('device-pairing-state', handler);
    return () => ipcRenderer.removeListener('device-pairing-state', handler);
  },
});
