# PCVR motion extrapolation (ASW-style), plan

Status (2026-11-17): step 1 (probe) done, idle and with the game running, and it is a go. Steps 2 and 3
(host and headset) built; the first headset run wobbled, and the cause was found and fixed (below, "First
headset run"). Step 4 (HUD mask) built: the broker marks head-locked quads in alpha, the host in the depth
picture's chroma, the headset shows them head-locked (NATIVE_V3_PROTOCOL.md section 4.8). Step 5 (device run
of the fix and the mask) is open.

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
2. **The motion on the depth frames (wire).** Built as a side data item rather than a stream of its own:
   `motionField` (type 5, capability `motionField` 25, NATIVE_V3_PROTOCOL.md section 4.8) on each depth
   frame, so it shares the depth frame's number, FEC, NACK and decode, and needs no second decoder. Per
   32x32 block of each render eye (80x64 for 2536x2040), x and y as signed bytes of a render pixel, 20 KB a
   frame (7 Mbps at 45 fps), next to the depth picture's few Mbps. A video stream would be smaller, but
   it would need its own format, sender, receiver, recovery and decoder for a grid this size.
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

**With the game running** (Cyberpunk at the 45 lock, DLSS Balanced, game present p99 22.7 ms, GPU 83-93%,
the spike host encoding the 5072x2040 stream at 45 on the same encoder; `C:\lwvr\motion-load.ps1`). The
probe now reads its two pictures back before each estimate, so their draws, queued behind the game on the
3D engine, are not counted in it:

| searched per eye | ME time mean / p50 / p95 | gain | frames gained |
|---|---|---|---|
| 634x510 | 4.2 / 3.7 / 7.0 ms | +2.6 dB | 164 of 168 |
| 1268x1020 | 7.3 / 7.0 / 9.7 ms | +3.2 dB | 166 of 168 |

The time is nearly all waiting for the one encoder engine, which the colour encode holds 8-13 ms a frame;
the probe also ran its estimates back to back (about 4x the stream's rate), so it queued harder than one
estimate per frame would. That is over the 4 ms aimed for at p95, but the estimate runs beside the colour
encode, not in series with it: on its own thread, like depth, its picture reaches the headset with the
depth picture well before the repeat it is for (half a period after the frame is first shown). The game
held 45 throughout. Quarter size it is.

## What was built (2026-11-17)

- **Host** (`longwave-pcvr-host`, `--motion on|off`, default on; only for a viewer that negotiated
  `motionField`): the encode thread scales each frame to a quarter (`MotionFieldBuilder.searchEye`, 640x512 an
  eye for 2536x2040, whole 8-pixel blocks so none straddles the eyes) through the warp pass, queued ahead of
  the colour encode like the depth pass. The depth thread runs the search (`MotionSearch`, `lw_motion` with
  8x8 output blocks) against the previous picture, at most 100 ms older, before it encodes the depth, and
  `MotionFieldBuilder.field` turns it into the item: the vectors under each 32-pixel cell, scaled to render
  pixels, minus the motion the change of render orientation explains for a world at infinity (the head's
  translation is left in: a pixel or two at a metre over one frame), a 3x3 median of the known cells, and
  quantised. Stats on the depth line: fields, search time, Mbps, the game motion's mean length.
- **Headset**: `PCVRV3Remote` offers `motionField` with depth and hands each item to the depth store's
  entry as a `PCVRMotionMap` (an `rg16Float` texture of both eyes' blocks). `PCVRShellRenderer` records when
  each frame was first shown; a repeat of it whose depth entry has the same frame number gets a
  `PCVRMotionShift` of `(now - first shown) / interval`, at most 1, and the warp reads the picture at
  `uv + amount * v` (`pcvrMotionShift`, in both the display-view and the compute paths). Switch:
  `pcvrShellControl motion=false`; stats `motionShifts`, `motionMeanPixels`.
- **Tests**: `SideDataTests` (golden item, rejects), `MotionFieldBuilderTests` (a turn's motion is removed
  and the game's kept, unknown and stray blocks), `PCVRDepthWarpTests.testARepeatCarriesTheGamesMotionOnByTheTimeSinceTheFirstDisplay`.
- **Not done**: the HUD mask (step 4); motion is per 32-pixel block read bilinearly, so moving silhouettes
  will warble (a depth-aware split is the next refinement); the field's age is not checked against the
  colour frame beyond the frame number.

## First headset run (2026-11-17): it wobbled

The host searched the raw frames and subtracted the motion the head's turn explains. NVENC's search does not
see that turn on flat or repeating texture ("no motion" matches there as well as the true one), so subtracting
the turn from such a block left false motion the size of the turn, which the headset then carried on. The
bench's head shake (`--mode motion`, `LW_MOTION_ROTATION_ONLY=1`): the search read 9.7 px a frame against the
turn's 16.4 px (the turn moves a rectilinear picture's edges up to 4x its centre, and the search caught little
of it; near the centre it read 4 px of 14), and 10.8 px of false motion was left.

Fix, as Oculus ASW did it: the previous search picture is turned to the current render orientation first
(`lw_reproject`, a homography per eye, `MotionFieldBuilder.previousFromCurrent`) and searched against that, so
a still world matches at zero everywhere. False motion left on the same shake: 1.3 px, under 3% of blocks over
one search pixel after the median. Blocks whose content the turn brings in from outside the previous picture
are marked unknown; motion under one search pixel is sent as still. On real Cyberpunk frames with the head
still (`--motion-probe`, no viewer) the search found no motion on any of 10,112 blocks.

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
