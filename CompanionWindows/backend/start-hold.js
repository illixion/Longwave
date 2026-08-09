// Bring the hotspot up via the backend RPC and hold it, printing join info + live client
// count, so a phone / Vision Pro can join for an end-to-end test. Auto-stops after the hold.
//   node start-hold.js [ssid] [passphrase] [holdSeconds]
const net = require('net');
const PIPE = '\\\\.\\pipe\\longwave-hotspot';

const ssid = process.argv[2] || 'Longwave-Demo';
const pass = process.argv[3] || 'vnc4Kxyz';
const hold = parseInt(process.argv[4] || '180', 10);

const sock = net.connect(PIPE);
let buf = '', nextId = 1;
const pending = new Map();
sock.setEncoding('utf8');

sock.on('data', (chunk) => {
  buf += chunk; let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
    if (!line) continue;
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.event === 'state') {
      const d = m.data;
      console.log(`  [state] ${d.state}  clients=${d.clientCount}/${d.maxClientCount}  gw=${d.gatewayIp || '-'}`);
      continue;
    }
    const p = pending.get(m.id); if (p) { pending.delete(m.id); p(m.result ?? m.error); }
  }
});
sock.on('error', (e) => { console.error('socket error:', e.message); process.exit(1); });

function rpc(method, params) {
  const id = nextId++; const req = { id, method }; if (params) req.params = params;
  return new Promise((res, rej) => {
    const t = setTimeout(() => { pending.delete(id); rej(new Error('timeout ' + method)); }, 30000);
    pending.set(id, (r) => { clearTimeout(t); res(r); });
    sock.write(JSON.stringify(req) + '\n');
  });
}

sock.on('connect', async () => {
  console.log(`Starting hotspot SSID='${ssid}' ...`);
  const r = await rpc('StartHotspot', { ssid, passphrase: pass, band: 'auto' });
  if (!r.ok) { console.error('START FAILED:', r.status, r.detail); sock.end(); process.exit(2); }
  const s = r.snapshot;
  console.log('\n==================== JOIN FROM A DEVICE ====================');
  console.log(`  Wi-Fi network : ${s.ssid}`);
  console.log(`  Password      : ${s.passphrase}`);
  console.log(`  Gateway IP    : ${s.gatewayIp}   <-- type this into Longwave`);
  console.log(`  Upstream      : ${s.upstreamName} (${s.upstreamKind})`);
  console.log(`  Clients       : ${s.clientCount}/${s.maxClientCount}`);
  console.log('============================================================\n');
  console.log(`Holding ${hold}s. Watching for clients...`);
  setTimeout(async () => {
    console.log('Hold elapsed; stopping hotspot.');
    await rpc('StopHotspot');
    sock.end(); process.exit(0);
  }, hold * 1000);
});
