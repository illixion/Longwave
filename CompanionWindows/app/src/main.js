'use strict';
const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { spawn } = require('child_process');
const { HotspotClient } = require('./pipe-client');

let mainWindow = null;
let backendProc = null;
const client = new HotspotClient();

// Unambiguous WPA2 alphabet (mirrors the backend Tokens.cs — no 0/O/1/l/I).
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
function randomToken(len) {
  const bytes = crypto.randomBytes(len);
  let s = '';
  for (let i = 0; i < len; i++) s += ALPHABET[bytes[i] % ALPHABET.length];
  return s;
}

/** Locate the backend exe in packaged resources or the dev build output. */
function resolveBackendExe() {
  const name = 'VisionVNCHotspotBackend.exe';
  const candidates = app.isPackaged
    ? [path.join(process.resourcesPath, 'backend', name)]
    : [
        path.join(__dirname, '..', '..', 'backend', 'bin', 'Release', 'net8.0-windows10.0.22621.0', 'publish', name),
        path.join(__dirname, '..', '..', 'backend', 'bin', 'Release', 'net8.0-windows10.0.22621.0', name),
      ];
  return candidates.find((p) => fs.existsSync(p)) || null;
}

/**
 * Start the privileged backend as an interactive-session helper. Electron runs elevated
 * (requireAdministrator), so the spawned child inherits elevation — no Session-0 service
 * required for the PoC. If the backend is already running as a service, the spawn simply
 * fails to bind the pipe and exits; we connect to whichever instance owns the pipe.
 */
function startBackend() {
  if (process.env.VISIONVNC_NO_SPAWN === '1') return;
  const exe = resolveBackendExe();
  if (!exe) {
    console.warn('[main] backend exe not found; expecting an externally-run backend/service.');
    return;
  }
  console.log('[main] launching backend:', exe);
  backendProc = spawn(exe, [], { windowsHide: true, stdio: 'ignore' });
  backendProc.on('exit', (code) => {
    console.log('[main] backend exited with code', code);
    backendProc = null;
  });
  backendProc.on('error', (e) => console.error('[main] backend spawn error:', e.message));
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1000,
    height: 720,
    minWidth: 860,
    minHeight: 620,
    title: 'VisionVNC Companion',
    icon: path.join(__dirname, '..', 'buildResources', 'icon.ico'),
    backgroundColor: '#1b1a18',
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  mainWindow.removeMenu();
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));

  const send = (channel, payload) => {
    if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(channel, payload);
  };
  client.on('connected', () => send('connection', true));
  client.on('disconnected', () => send('connection', false));
  client.on('notify', (event, data) => send('notify', { event, data }));
}

// ---- IPC bridge: renderer -> backend RPC ----
ipcMain.handle('rpc', async (_e, method, params) => {
  return client.rpc(method, params);
});
ipcMain.handle('get-connection', () => client.connected);
ipcMain.handle('gen-passphrase', () => randomToken(8));
ipcMain.handle('gen-ssid', () => `VisionVNC-${randomToken(4)}`);

app.whenReady().then(() => {
  startBackend();
  client.start();
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  app.quit();
});

app.on('before-quit', () => {
  client.stop();
  // Leave a service-hosted backend running; only tear down a child we spawned.
  if (backendProc) {
    try { backendProc.kill(); } catch { /* ignore */ }
  }
});
