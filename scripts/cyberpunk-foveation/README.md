# Fixed foveation for Cyberpunk 2077 VR over Longwave PCVR

Work on the Cyberpunk VR port (`dariulone/cyberpunk-vr-port`, MIT, 0.2.45 at `6f33af6`) to make the periphery of
each eye cheaper on the gaming PC (RTX 3080, Ryzen 5 5600X), measured 2026-11-17. Everything here is a patch against
the port or a tool that drives it; none of it ships in Longwave.

## What the frame costs (2536x2040 per eye, DLSS Balanced, engine stereo, uncapped: 18.2-18.6 ms, 54-56 fps)

GPU time per render-graph node, from the port's own profiler (`prof.py`):

| node | ms | kind |
|---|---|---|
| ApplyDLSS (port's foveated DLSS on) | 2.8-3.0 | compute, output size |
| DrawConeAO | 2.3-2.5 | async compute, internal size |
| RenderElements (depth, G-buffer, decals) | 1.6-1.8 | raster |
| VolumetricFog | 1.2-1.4 | compute, froxels |
| RenderLightsIntegrate | 1.1-1.3 | full-screen pixel shader |
| ScreenSpaceReflections | 1.0-1.3 | compute |
| RenderLightBuffers | 0.9-1.0 | compute (indirect) |
| Present, bloom, CAS, the rest | ~2.5 | |

What each compute pass costs the FRAME, measured by not sending its dispatches (`skip.ps1`, the
`CyberpunkVR_FfrSkipNode` probe; the picture is broken while it is on):

| pass skipped | frame median | change |
|---|---|---|
| none | 18.6 ms | |
| DrawConeAO | 15.7 ms | -2.9 ms (-16 %) |
| ScreenSpaceReflections | 16.6 ms | -2.0 ms (-11 %) |
| VolumetricFog | 17.0 ms | -1.6 ms (-9 %) |
| RenderLightBuffers | 17.8 ms | -0.8 ms (-4 %) |
| CAS | 18.7 ms | none |

## Findings

- **The port's VRS and hidden-area mask are switched off under engine stereo** (`FixedVrs.cpp` `SetSettings`,
  `HiddenArea.cpp:173`), the mode 0.2.45 runs by default. Earlier `xr_vrs` and `xr_hidden_area` tests on this PC
  measured nothing.
- **VRS, once it works in the side-by-side frame and covers every pass, is worth 2 %** (map: 70 x 65 % centre, 4x4
  beyond): 17.9 -> 17.5 ms. Its ceiling, the WHOLE frame at 4x4, is 9 % (16.3 ms); whole frame 2x2 is 6 %. The
  G-buffer material shaders export depth, which forces fine shading (D3D12 VRS spec), and the heavy passes are
  compute, which VRS does not reach.
- **The money is in three compute passes: cone AO, SSR and volumetric fog are 35 % of the frame.**
- **Foveated cone AO works: -7 % frame time** (18.15 -> 16.9 ms, 56.0 -> 60.0 fps, ABBA). Outside an ellipse of
  0.40 x 0.38 of each eye's image (48 % of the eye kept) the two heavy AO shaders store "unoccluded" and return. With
  the VRS map on top: 16.7 ms (-8 %).
- **Foveated SSR: -4 % on its own.** The tile classifier files a 32-pixel tile whose centre is outside the same
  ellipse in its clear list at once, and no thread of it traces. The node goes from 1.25 to 0.50 ms.
- **All three together: 18.5 -> 16.2 ms, 54.5 -> 61.8 fps (-12 % frame time), 1 % low 48 -> 56 fps**
  (`all.ps1`, one launch: off 18.5, AO 17.6, SSR 17.8, AO + SSR 16.8, AO + SSR + VRS 16.2, off 18.5). "Off" here
  also turns off the port's own AO and SSR corrections, which its author measured at 0.23 ms for all groups.
- A fine checkerboard would not do the same: compute threads run in warps of 32, so only contiguous regions that
  empty whole thread groups save time.

## What is here

- `port-build.patch`: the port builds without cargo (redscript's compiler is only copied beside the DLL) and without
  the `tools/rtti_dump` folder the repository does not have. Build against upstream `wopss/RED4ext.SDK` master of the
  port's commit date (`a34f0ad0`), not the stale submodule: `-DCVR_RED4EXT_SDK_DIR=...` (`build.ps1`).
- `port-foveation.patch`:
  - fixed VRS under engine stereo: the rate map covers the side-by-side frame, each half foveated on its own,
    `xr_vrs_offset_x` towards the nose; eye viewports are recognised by a right half seen at the same size;
  - `CyberpunkVR_FixedVrsScope` (live export; 0 = the port's rule, opaque G-buffer pipelines; 1 = all of
    RenderElements; 2 = every node drawing into an eye-sized viewport, the default);
  - `CyberpunkVR_FixedVrsUniform` (1 / 2 = whole frame 2x2 / 4x4, measurement only);
  - `CyberpunkVR_FfrSkipNode` / `FfrSkipKinds` (a node's dispatches / indirect commands not sent, measurement only).
- `fov_shaders.py`: builds the foveated AO twins with the port's recipe tools (`tools/hidden_area_tests`) and its
  `dxil_tool` (compile `tools/single_pass_tests/dxil_tool.cpp`, link `ole32.lib`). `65e542c0719b464d` (8x8 pass) is
  made from the engine's shader; `33f28d9a0e7a8352` (the main trace, 1.6 of the node's 2.2 ms) from the port's own
  two-eye twin in `shaders\asym_ao`; `bdf51af7acfab45e` (the SSR tile classifier) from the engine's shader. The AO
  outputs go into `shaders\asym_ao\`, the classifier into `shaders\asym_ssr\`, named by the engine shader's hash;
  the groups' live switches are `CyberpunkVR_AsymAoPatch` and `CyberpunkVR_AsymSsrPatch`.
- `rollback.ps1`: the shipped DLL and twins back (backups under `C:\lwvr\cpvr`).
- `prof.py`, `ab.py`, `detail.py`, `census.py`, `setx.py`, `skip.ps1`, `ao.ps1`: profile per node, A/B live exports,
  per-pipeline detail of a node, the shader census (needs `log\cvr_shader_census.txt` at game start), set an export,
  and the two measurement runs above. Frame rate is PresentMon's (`C:\lwvr\pm-capture.ps1`), launches are
  `C:\lwvr\res-test.ps1` on the gaming PC.

## Next

1. Headset check, not done yet: nothing here has been seen in the headset. The AO ellipse has a hard edge and a
   straight bent normal outside; SSR ends in 32-pixel steps. Is either border visible, and at what size? A feather
   and the surface normal instead of the straight one are the first fixes for AO if it is.
2. Volumetric fog: froxels outside the ellipse, about -0.6 ms if its three shaders skip cleanly.
3. The ellipse as placeholders rewritten at run time (the port's `DxilPatch`), with an overlay slider, instead of
   constants baked into the twin.
