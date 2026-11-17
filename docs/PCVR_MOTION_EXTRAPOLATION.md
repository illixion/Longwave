# PCVR motion extrapolation (ASW-style), plan

Status: step 1 (probe) done 2026-11-17 and it is a go; steps 2-5 not started.

## Why

A game that holds 45 fps on a 90 Hz Vision Pro shows every frame twice. The headset's depth warp
corrects each display frame for the wearer's head, so turning is smooth, but anything that moves in the
game itself (cars, and the whole world while walking or driving) steps every 22 ms and doubles on the
retina. Measured on the Cyberpunk port (2026-11-17): the lock leaves the game sharp and steady (DLSS
Balanced + Transformer, p99 22.7 ms), and this judder is what is left.

The two cheap alternatives were tried and do not work on an RTX 3080:

- **The port's own frame generation at a 90 Hz stream.** The game makes ~86 fps (43 real + 43
  generated), but the GPU reaches 99%, the host's render stage (ring texture to encoder input) waits
  54-57 ms behind the game, and the stream falls to 26 fps.
- **More real frames.** The GPU is the limit (Balanced runs ~58 fps unlocked); an unlocked rate on 90 Hz
  is uneven instead of doubled.

So the missing frame has to be made without the 3D engine of a busy GPU.

## Design

1. **Motion from the video encoder's own motion estimation (PC).** NVENC has a motion-estimation-only
   mode (`nvEncRunMotionEstimationOnly`) that runs on the encoder engine, not the 3D engine: what Oculus
   ASW 1.0 used. A second NVENC session in ME-only mode takes the frame being encoded and the previous
   one (the ring textures already registered with NVENC, BGRA) and returns quarter-pel vectors per
   coding unit. HEVC, because H.264 ME is limited to 4096 wide and the side-by-side picture is 5072. The
   HEVC output is per CU in Z-order inside each CTB (`NV_ENC_HEVC_MV_DATA`, `lastCUInCTB`); it is
   rebuilt into a 16x16-block grid per eye and cleaned (median of neighbours, intra blocks and high-cost
   blocks marked unknown).
2. **A small motion picture beside depth (wire).** Per eye a 2-channel grid (2536x2040 / 16 = 159x128),
   motion in pixels per frame, sent like the depth picture: its own capability (`motionVideo`), an 8-bit
   HEVC picture (x and y as two halves of the luma, a fixed scale and offset in the format), keyed to
   the colour frame's number. About 1 Mbps.
3. **Extrapolation in the headset warp.** On a display frame that repeats the current stream frame,
   the warp samples the colour at `s - a * mv(s)`, where `s` is the source position the depth warp
   already computes and `a` is how far the display time is past the frame's own time in source periods
   (0.5 for the repeat at 45 on 90). One more texture read in the map pass; the warp's GPU budget tiers
   cover it. HUD quads are composited by the broker into the eye images, so they would wobble with the
   motion under them: the broker can write a HUD mask (the quads' coverage) that zeroes motion there.

Expected artefacts are ASW 1.0's: warbling at disocclusions and on transparent or flat content. The
motion is from frame N-1 to N, extrapolated forward, so no latency is added (interpolation would add a
frame).

**Motion caused by the head is not extrapolated.** The headset warp already moves each frame from its
render pose to the display pose, so the host subtracts the image motion that the pose change between the
two frames explains (rotation per eye, plus depth for the translation) and sends only what is left: the
game's own motion (objects, locomotion). Oculus ASW does the same by reprojecting the previous frame to
the current pose before searching.

## Probe results (RTX 3080, idle GPU, test scene on the `shake` trajectory, 2026-11-17)

`pcvr-codec-bench --mode motion --preset 1` (`LW_MOTION_EYE=WxH` sets the size searched). Scored on the
left eye's centre against the truth half a 45 Hz period later, frames with motion only:

| searched per eye | ME time mean / p95 | repeat | extrapolated | gain |
|---|---|---|---|---|
| 2536x2040 | 20.7 / 21.6 ms | 12.20 dB | 14.98 dB | +2.8 dB, 22 of 22 frames |
| 1268x1020 | 6.5 / 9.3 ms | 26.30 dB | 30.45 dB | +4.2 dB, 44 of 44 |
| 634x510 | 1.75 / 1.8 ms | 27.48 dB | 30.03 dB | +2.5 dB, 43 of 44 |

- The time is the encoder engine's (submit 0.1 ms, parse 1.2 ms on the CPU); the preset makes no
  difference. 634x510 per eye fits beside the colour encode (12-17 ms of a 22 ms frame at 45 fps) and is
  the depth picture's size; the downscale belongs in the host's existing render pass.
- Convention confirmed: current(p) matches reference(p + v); the other sign scores below repeating.
- HEVC records: 32x32 CTBs in raster order over the picture padded to whole CTBs (edge CTBs coded whole,
  no implicit split), CUs in z-order, `lastCUInCTB` ends each CTB; the MV buffer is a fixed size with
  stale records after the last CTB. The driver refuses a tuning hint and the preset's multi-pass in
  this mode.
- Still to measure: the same with the game running at 45 (encoder engine shared with the colour encode).

## Steps and checks

1. **Probe (PC, no headset):** `lw_motion` in CStreamWin (ME-only session, HEVC MV parse into a grid)
   and `pcvr-codec-bench --mode motion`: ME time per frame with and without the game running at 45, and
   how well `frame N-1 moved by its motion` predicts frame N against simply repeating N-1 (PSNR /
   SSIM over the bench's ray-cast scene and over a recorded game stream). Go/no-go: ME under 4 ms on
   the encoder engine with the game running, and a clear gain over repeating.
2. Host: run ME on every encoded frame, publish the motion picture (format, side data, depth-style
   encoder), behind a host flag.
3. Headset: decode, store by frame number like `PCVRDepthStore`, apply in `PCVRDepthWarp` on repeated
   display frames, a `pcvrShellControl` switch to compare on and off, stats.
4. Broker: HUD mask.
5. Device run in Cyberpunk: cars and driving with and without.
