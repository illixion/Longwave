// STA+AP concurrency test: start the hotspot sharing the *Wi-Fi* upstream (the café scenario),
// so the single adapter must stay connected as a station AND host the AP. Leaves the AP up so
// the STA link can be inspected separately.
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
sock.on('connect', async () => {
  const ups = await rpc('ListUpstreamProfiles');
  console.log('Upstreams:', JSON.stringify(ups));
  const wifi = ups.find((u) => u.kind === 'wifi' && u.hasInternet);
  if (!wifi) { console.error('No Wi-Fi upstream with internet found'); sock.end(); process.exit(2); }
  console.log(`Sharing Wi-Fi upstream: ${wifi.name} (${wifi.id})`);
  const band = process.argv[2] || 'auto';
  const r = await rpc('StartHotspot', { ssid: 'Longwave-STAAP', passphrase: 'staap123', band, profileId: wifi.id });
  console.log('StartHotspot ->', JSON.stringify(r));
  sock.end(); process.exit(r.ok ? 0 : 3);
});
