// Calls a single RPC (default PrepareApAdapter) and prints the result, leaving state as-is.
const net = require('net');
const method = process.argv[2] || 'PrepareApAdapter';
const sock = net.connect('\\\\.\\pipe\\longwave-hotspot');
let buf = '', nextId = 1; const pending = new Map();
sock.setEncoding('utf8');
sock.on('data', (c) => { buf += c; let nl;
  while ((nl = buf.indexOf('\n')) >= 0) { const l = buf.slice(0, nl).trim(); buf = buf.slice(nl+1);
    if (!l) continue; let m; try { m = JSON.parse(l); } catch { continue; }
    if (m.event) continue; const p = pending.get(m.id); if (p) { pending.delete(m.id); p(m.result ?? m.error); } } });
sock.on('error', (e) => { console.error('socket error:', e.message); process.exit(1); });
function rpc(method) { const id = nextId++; return new Promise((res) => { pending.set(id, res); sock.write(JSON.stringify({id, method}) + '\n'); }); }
sock.on('connect', async () => { console.log(method, '->', JSON.stringify(await rpc(method))); sock.end(); process.exit(0); });
