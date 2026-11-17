"""Per-node GPU profile of the running game through the port's own exports.
usage: python prof.py <pid> [rounds]"""
import statistics, sys, time
from pathlib import Path
sys.path.insert(0, r'C:\lwvr\cpvr\repo\tools\vr_bench')
import vr_bench as vb
vb.GAME = Path(r'F:\Games\Cyberpunk 2077')
vb.DLL = vb.GAME / 'red4ext/plugins/cyberpunkvrport/cyberpunkvrport.dll'
pid = int(sys.argv[1]); rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 3
g = vb.Game(pid)
names = vb.node_names()
c0, g0 = g.ring_counts(); time.sleep(4); c1, g1 = g.ring_counts()
cpu = g.ring('CyberpunkVR_FrameRingCpu', c0, c1); gpu = g.ring('CyberpunkVR_FrameRingGpu', g0, g1)
if cpu and gpu:
    print(f'frames {len(cpu)} in 4 s; cpu interval p50 {statistics.median(cpu):.2f} ms; gpu p50 {statistics.median(gpu):.2f} ms')
profs = []
for _ in range(rounds):
    profs.append(vb.scene_profile(g, frames=4)); time.sleep(0.5)
s = vb.summarize_profiles(profs, names)
print(f"profiled frames {s['frames']}; totals " + ' '.join(f'{k}={v:.2f}' for k, v in s['totals'].items()))
for r in s['nodes']:
    if r['total'] < 0.03: continue
    print(f"{r['total']:6.2f}  L{r['L']:5.2f} R{r['R']:5.2f} F{r['F']:5.2f} C{r['C']:5.2f} A{r['A']:5.2f} O{r['O']:5.2f}  cmds {r['commands']/s['frames']:7.0f}  {r['node']} {r['name']}")
