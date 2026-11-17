"""Shader census of the heavy compute nodes: python census.py <pid>  (needs cvr_shader_census.txt beside the exe at start)"""
import json, sys
from pathlib import Path
sys.path.insert(0, r'C:\lwvr\cpvr\repo\tools\vr_bench')
import vr_bench as vb
vb.GAME = Path(r'F:\Games\Cyberpunk 2077'); vb.DLL = vb.GAME / 'red4ext/plugins/cyberpunkvrport/cyberpunkvrport.dll'
g = vb.Game(int(sys.argv[1]))
r = vb.census(g, seconds=1.0)
if 'error' in r: print(r); sys.exit(1)
want = {'DrawConeAO', 'ScreenSpaceReflections', 'RenderLightBuffers', 'VolumetricFog', 'RenderLightsIntegrate', 'ApplyContrastAdaptiveSharpening'}
for row in r['rows']:
    if row['name'] in want:
        print(f"{row['name']:24s} side {row['side']:2d} {str(row['kind']):10s} size {row['size']} shader {row['shader']} count {row['count']}")
json.dump(r, open(r'C:\lwvr\cpvr\census.json', 'w'))
