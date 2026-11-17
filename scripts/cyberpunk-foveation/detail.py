"""Per-range GPU detail of one node, and the AO twin group's counters: python detail.py <pid> <node hex>"""
import json, sys
from pathlib import Path
sys.path.insert(0, r'C:\lwvr\cpvr\repo\tools\vr_bench')
import vr_bench as vb
vb.GAME = Path(r'F:\Games\Cyberpunk 2077'); vb.DLL = vb.GAME / 'red4ext/plugins/cyberpunkvrport/cyberpunkvrport.dll'
extra = ['CyberpunkVR_AsymAoPatch', 'CyberpunkVR_AsymAoPatchLoaded', 'CyberpunkVR_AsymAoPatchBuilt', 'CyberpunkVR_AsymAoPatchFailed', 'CyberpunkVR_AsymAoPatchBinds']
vb.SYMBOLS = vb.SYMBOLS + extra
g = vb.Game(int(sys.argv[1]))
print({k[len('CyberpunkVR_'):]: (g.u64(k) if k.endswith('Binds') else g.u32(k)) for k in extra})
r = vb.node_detail_profile(g, int(sys.argv[2], 16), frames=4)
print(json.dumps(r)[:6000])
