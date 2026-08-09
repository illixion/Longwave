// Named-pipe RPC smoke test using Node's net module — the same transport the Electron
// main process will use. Sends Ping/ListUpstreamProfiles/GetStatus/StartHotspot/StopHotspot.
const net = require('net');
const PIPE = '\\\\.\\pipe\\longwave-hotspot';

const sock = net.connect(PIPE);
let buf = '';
let nextId = 1;
const pending = new Map();

sock.setEncoding('utf8');
sock.on('connect', async () => {
  console.log('connected');
  try {
    console.log('Ping ->', JSON.stringify(await rpc('Ping')));
    console.log('ListUpstreamProfiles ->', JSON.stringify(await rpc('ListUpstreamProfiles')));
    console.log('GetStatus ->', JSON.stringify(await rpc('GetStatus')));
    console.log('StartHotspot ->', JSON.stringify(await rpc('StartHotspot', { ssid: 'Longwave-Test', band: 'auto' })));
    console.log('StopHotspot ->', JSON.stringify(await rpc('StopHotspot')));
  } catch (e) {
    console.error('RPC error:', e.message);
  }
  sock.end();
  process.exit(0);
});

sock.on('data', (chunk) => {
  buf += chunk;
  let nl;
  while ((nl = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { console.error('parse fail:', line); continue; }
    if (msg.event) { console.log(`  [event:${msg.event}] state=${msg.data?.state} clients=${msg.data?.clientCount}/${msg.data?.maxClientCount} canHostAp=${msg.data?.canHostAp}`); continue; }
    const p = pending.get(msg.id);
    if (p) { pending.delete(msg.id); p(msg); }
  }
});

sock.on('error', (e) => { console.error('socket error:', e.message); process.exit(1); });

function rpc(method, params) {
  const id = nextId++;
  const req = { id, method };
  if (params) req.params = params;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`timeout waiting for ${method}`)); }, 15000);
    pending.set(id, (msg) => { clearTimeout(timer); resolve(msg.result ?? msg.error); });
    sock.write(JSON.stringify(req) + '\n');
  });
}
