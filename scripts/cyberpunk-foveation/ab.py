"""Same-launch A/B of live 32-bit exports, by per-node GPU time.
usage: python ab.py <pid> <reps> "label:Name=val;Name2=val" ["label2:..."]
Variants take turns (A B B A ...). Prints per variant the mean GPU ms summed over nodes and the main nodes."""
import json, statistics, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, r'C:\lwvr\cpvr\repo\tools\vr_bench')
import vr_bench as vb
vb.GAME = Path(r'F:\Games\Cyberpunk 2077')
vb.DLL = vb.GAME / 'red4ext/plugins/cyberpunkvrport/cyberpunkvrport.dll'
pid, reps = int(sys.argv[1]), int(sys.argv[2])
variants = []
for text in sys.argv[3:]:
    label, _, body = text.partition(':')
    variants.append((label, [(k, int(v, 0)) for k, v in (p.split('=') for p in body.split(';') if p)]))
extra = sorted({k for _, sets in variants for k, _ in sets} | {'CyberpunkVR_FixedVrsReport', 'CyberpunkVR_FixedVrsReportSeq'})
vb.SYMBOLS = list(dict.fromkeys(vb.SYMBOLS + extra))
g = vb.Game(pid)
names = vb.node_names()
original = {k: g.u32(k) for _, sets in variants for k, _ in sets}
KEY = ['ApplyDLSS', 'DrawConeAO', 'RenderElements', 'VolumetricFog', 'RenderLightsIntegrate', 'ScreenSpaceReflections',
       'RenderLightBuffers', 'Present', 'ApplyBloomAndTonemapping', 'RenderShadowmask', 'RenderFogOverlay']
rows = {label: [] for label, _ in variants}
order = []
for r in range(reps):
    order += variants if r % 2 == 0 else variants[::-1]
try:
    for label, sets in order:
        for k, v in original.items(): g.set32(k, v)
        for k, v in sets: g.set32(k, v)
        time.sleep(4)
        profs = []
        for _ in range(3):
            profs.append(vb.scene_profile(g, frames=4)); time.sleep(0.3)
        s = vb.summarize_profiles(profs, names)
        by = {r['name']: r['total'] for r in s['nodes']}
        smi = subprocess.run(['nvidia-smi', '--query-gpu=utilization.gpu', '--format=csv,noheader,nounits'], capture_output=True, text=True).stdout.strip()
        try: rep = g.seqlock('CyberpunkVR_FixedVrsReport', 'CyberpunkVR_FixedVrsReportSeq', 1024)
        except Exception as e: rep = {'error': str(e)}
        rows[label].append(dict(all=s['totals']['all'], util=float(smi or 0), nodes=by, vrs=rep))
finally:
    for k, v in original.items(): g.set32(k, v)
for label, _ in variants:
    rs = rows[label]
    print(f"{label:14s} all {statistics.mean(r['all'] for r in rs):6.2f} ms ({' '.join(f'{r['all']:.2f}' for r in rs)})  util {statistics.mean(r['util'] for r in rs):.0f}%")
    print('   ' + '  '.join(f"{k[:14]} {statistics.mean(r['nodes'].get(k, 0) for r in rs):.2f}" for k in KEY))
    v = rs[-1]['vrs']
    print('   vrs', {k: v.get(k) for k in ('requested', 'applied', 'supported', 'additional', 'failed', 'maps', 'draws', 'scene', 'eligible', 'error') if k in v})
