'use strict';
const { contextBridge, ipcRenderer } = require('electron');

// The notices window renders THIRD_PARTY_NOTICES.md itself rather than a hand-kept HTML
// copy of it. A licence page that has quietly drifted from the file it claims to mirror is
// worse than no page at all, so there is exactly one source and it is the markdown.
contextBridge.exposeInMainWorld('notices', {
  read: () => ipcRenderer.invoke('notices-read'),
  // Links in the notices go to the user's browser, never to this window: a licence page
  // that can be navigated is a web view with extra steps.
  openExternal: (url) => ipcRenderer.invoke('notices-open-external', url),
});
