'use strict';
// Tailscale CLI helpers for the main process: node status, self-IP resolution, and
// the DERP path check. A DERP-relayed connection can't carry CloudXR's 4×4096²
// media streams, so the UI surfaces relay vs direct for tailnet-mode sessions.
const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');

function cliPath() {
  const pf = process.env.ProgramFiles || 'C:\\Program Files';
  const candidate = path.join(pf, 'Tailscale', 'tailscale.exe');
  return fs.existsSync(candidate) ? candidate : 'tailscale';
}

function run(args) {
  return new Promise((resolve) => {
    execFile(cliPath(), args, { timeout: 20000, windowsHide: true }, (err, stdout, stderr) => {
      resolve({ code: err && typeof err.code === 'number' ? err.code : err ? -1 : 0, out: stdout || '', err: stderr || '' });
    });
  });
}

/** { installed, backendState, selfIp, selfName } */
async function tailscaleStatus() {
  const { code, out } = await run(['status', '--json']);
  if (code !== 0 && !out) return { installed: code !== -1, backendState: 'unknown', selfIp: null, selfName: null };
  try {
    const j = JSON.parse(out);
    const ips = (j && j.Self && j.Self.TailscaleIPs) || [];
    return {
      installed: true,
      backendState: (j && j.BackendState) || 'unknown',
      selfIp: ips.find((ip) => ip.includes('.')) || null,
      selfName: (j && j.Self && j.Self.HostName) || null,
    };
  } catch {
    return { installed: true, backendState: 'unknown', selfIp: null, selfName: null };
  }
}

/** `tailscale ping` forces path discovery: { ok, direct, detail }. */
async function checkPath(ip) {
  const { code, out, err } = await run(['ping', '-c', '2', '--timeout', '2s', ip]);
  const text = (out + '\n' + err).trim();
  const lastPong = text.split('\n').filter((l) => l.includes('pong from')).pop();
  if (lastPong) {
    const derp = lastPong.match(/via DERP\(([^)]*)\)/);
    if (derp) return { ok: true, direct: false, detail: `RELAYED via DERP ${derp[1]}` };
    const via = lastPong.match(/via ([0-9a-fA-F.:[\]]+:\d+)/);
    return { ok: true, direct: true, detail: `direct via ${via ? via[1] : '?'}` };
  }
  return { ok: false, direct: false, detail: code === 0 ? 'no reply' : (text.split('\n')[0] || 'ping failed') };
}

module.exports = { tailscaleStatus, checkPath };
