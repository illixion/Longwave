// Exercises the guided adapter-disable flow with both Wi-Fi adapters enabled:
// List -> Start (expect adapterConflict) -> PrepareApAdapter -> Start (expect success) -> Stop.
const net = require('net');
const sock = net.connect('\\\\.\\pipe\\longwave-hotspot');
let buf = '', nextId = 1; const pending = new Map();
sock.setEncoding('utf8');
sock.on('data', (c) => { buf += c; let nl;
  while ((nl = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, nl).trim(); buf = buf.slice(nl+1);
    if (!l) continue; let m; try { m = JSON.parse(l); } catch { continue; }
    if (m.event) continue; const p = pending.get(m.id); if (p) { pending.delete(m.id); p(m.result ?? m.error); } } });
sock.on('error', (e) => { console.error('socket error:', e.message); process.exit(1); });
function rpc(method, params) { const id = nextId++; const r = {id, method}; if (params) r.params = params;
  return new Promise((res) => { pending.set(id, res); sock.write(JSON.stringify(r) + '\n'); }); }
const j = (o) => JSON.stringify(o);
sock.on('connect', async () => {
  console.log('Wi-Fi adapters:', j(await rpc('ListWifiAdapters')));
  let r = await rpc('StartHotspot', { ssid: 'Longwave-FixTest', passphrase: 'fixtest1', band: 'auto' });
  console.log('Start #1 ->', r.ok ? 'OK' : `FAIL status=${r.status} detail=${r.detail}`);
  if (!r.ok && r.status === 'adapterConflict') {
    console.log('Prepare ->', j(await rpc('PrepareApAdapter')));
    r = await rpc('StartHotspot', { ssid: 'Longwave-FixTest', passphrase: 'fixtest1', band: 'auto' });
    console.log('Start #2 ->', r.ok ? `OK state=${r.snapshot.state} gw=${r.snapshot.gatewayIp}` : `FAIL ${r.status} ${r.detail}`);
  }
  console.log('Stop ->', j(await rpc('StopHotspot')).slice(0, 80));
  sock.end(); process.exit(0);
});
