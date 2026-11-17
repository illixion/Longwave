"""Set live 32-bit exports of the port: python setx.py <pid> Name=val [Name=val ...]"""
import sys
from pathlib import Path
sys.path.insert(0, r'C:\lwvr\cpvr\repo\tools\vr_bench')
import vr_bench as vb
vb.GAME = Path(r'F:\Games\Cyberpunk 2077'); vb.DLL = vb.GAME / 'red4ext/plugins/cyberpunkvrport/cyberpunkvrport.dll'
pairs = [a.split('=') for a in sys.argv[2:]]
vb.SYMBOLS = [k for k, _ in pairs]
g = vb.Game(int(sys.argv[1]))
for k, v in pairs:
    old = g.u32(k); g.set32(k, int(v, 0)); print(f'{k}: {old} -> {g.u32(k)}')
