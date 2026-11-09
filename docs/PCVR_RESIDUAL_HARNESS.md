# Simulator harness for PCVR residual artifacts

Run this from the Longwave checkout. It does not deploy to or query the headset,
change PC settings, or change the running stream. It exercises the production
foveation mapping, unwarper, depth warper, eye-mesh builder, timed playout queue
and exact colour/depth pair selector against a ray-cast room.

```sh
python3 scripts/pcvr-residuals/run.py --out /private/tmp/pcvr-baseline
python3 scripts/pcvr-residuals/run.py --profile full --frames 2 --out /private/tmp/pcvr-matrix
```

The runner finds and boots an available Apple Vision Pro simulator. Override it
with `--simulator UDID`. `--derived-data PATH` reuses a build cache; keep it outside
`build/DerivedData*`, which build-and-sign prunes. The harness uses opt-in XCTest
methods in `PCVRWarpBenchTests`, and always disables diagnostic collection to avoid
the visionOS simulator's post-test diagnostic hang.

Open `index.html` in the output directory. It contains per-region scores, native
pixel PNG strips (**truth | stage output | error ×4**), zoom/stage/region controls,
and virtual timing results. PNGs are embedded in the HTML so the crops also work
when a browser restricts local-file access. `residual-report.json`, `metrics.csv`, `timing-report.json`,
`run.json` and `xcodebuild.log` support analysis and reproduction. Images are saved
for the first and last frame, while every frame contributes metrics. The runner
refuses to silently reuse an output directory containing a completed run.

## Stages and controls

- **sampling:** render source → centre/edge packing → production unwarp. No HEVC.
  This isolates resampling loss from the later reprojection stages.
- **warp:** production per-pixel depth reprojection, expanded only for comparison
  with a fresh ray-cast image at the warp target pose.
- **late-mesh-proxy:** production eye-mesh builder, using the warped depth, followed
  by a raster draw with the RK material's screen-affine sampling math at a later
  pose. This reproduces the geometry/sampling stage, not RK's renderer internals.
- **no-late-miss:** control where warp target and final display poses coincide.
  The test checks that the mesh proxy reproduces the warped image closely.
- **wrong-depth-control:** intentionally uses depth from two source frames earlier.
  This is a negative control; the production exact pairing path does not do it.

The smoke profile compares 8-bit and float depth plus the zero-late-miss control
at 60 Hz. The full profile covers 50/60/90/120 Hz, 8-bit/10-bit/float depth,
synthetic depth-block noise, wider overscan, longer pose age, wrong depth and a
half-rate source. Precision controls do not add new formats to the app's protocol.
All cases hold colour dimensions fixed, so wider overscan genuinely trades away
angular density. The 2592×2080 per-eye fixture is half the current 5184×4160 render
size per axis; its foveation ratios and asymmetric eye frusta match the receiver.

A separate virtual-time replay runs the real timed queue and pair selector under
4 ms and 12 ms GPU-busy models with delayed and missing depth. It asserts exact
pairing, monotonic output and bounded pending memory, and reports repetitions,
skipped ticks and frame-generation age. These budgets represent controlled test
inputs, not an emulation of Apple's thermal scheduler.

## Repeated runs and recorded motion

```sh
python3 scripts/pcvr-residuals/run.py --out /private/tmp/pcvr-candidate \
  --compare /private/tmp/pcvr-baseline/residual-report.json
python3 scripts/pcvr-residuals/run.py --report-only --out /private/tmp/pcvr-candidate
python3 scripts/pcvr-residuals/run.py --trajectory /path/to/existing-pose-recording.json \
  --out /private/tmp/pcvr-recorded-motion
```

Recorded input uses the existing `V3PoseRecorder` JSON (`rows`: time, xyz,
quaternion xyzw), rebased to the fixture head pose. No live recording is started.
The runner hashes the input, and baseline comparisons reject different motion,
fixture dimensions, scenario parameters or clock traces. Landmarks outside the
view are omitted, so baseline comparisons also reject missing region groups.
Only supply a trusted recording with sufficient duration for the selected run;
otherwise the existing trajectory sampler clamps at its endpoints.

The built-in synthetic motion is deterministic. Scene time advances by the
selected display interval, not wall-clock execution time. A slow Mac changes how
long the test takes, not the poses or images it requests.

## Metrics and limits

Scores are separate for the circle, left/right wall grids and floor. Linear-RGB
MAE and p95 measure image error; edge MAE and gradient error emphasize thin spokes
and grid lines. Temporal error measures changes in truth-relative error after
landmark centring; this is not full optical-flow alignment. Visibility masks from
ray-cast depth separate visible surfaces, disocclusions and outside-source pixels.

GPU times are scoped to individual processing command buffers: fixture packing,
the production depth warper, or mesh generation plus proxy draw. Reference scene
rendering, analysis-only expansion, scoring and PNG work are excluded. Each time
is repeated in its region rows; do not add the region rows together. They describe
this Mac's GPU, not Vision Pro GPU time, power draw or thermal behavior.

The harness does not model NVENC compression, the headset's HEVC decoder, RK's
temporal processing, the system compositor's late reprojection, eye optics,
passthrough blending or thermal policy. Synthetic block noise is explicitly a
stress input, not a codec simulator. A measured improvement here is a prerequisite
for headset comparison, not proof that the final view is fixed.

Validation of the analysis itself:

```sh
python3 -m unittest discover -s scripts/pcvr-residuals -p 'test_*.py'
```

`PCVRResidualMetricTests` also verifies zero truth error, camera-motion cancellation
in the defined temporal metric, and separation of visible/hidden/outside regions.

## Fixture version and receiver A/B

Reports carry `fixture` (`host-v2`: gaze centres snapped with
`CentreEdgeWarp.pixelAlignedCentre` and packed with the host's four-tap box
prefilter from `foveation_warp.cpp`, as the PC does). `--compare` refuses a
report from another fixture version; v1 reports (one unsnapped tap per wire
pixel) blurred the fovea by up to half a pixel in the sampling stage, an
artefact the host never produces.

The depth warper's colour filter is selectable for A/B runs without changing
the fixture, and is recorded as `warpFilter`:

```sh
TEST_RUNNER_PCVR_RESIDUAL_WARP_FILTER=bilinear python3 scripts/pcvr-residuals/run.py --out /private/tmp/pcvr-bilinear
python3 scripts/pcvr-residuals/run.py --out /private/tmp/pcvr-default \
  --compare /private/tmp/pcvr-bilinear/residual-report.json
```

Values are `PCVRDepthWarper.Resampling`'s raw values (`bilinear`,
`catmull-rom`, `catmull-rom-dering`); unset uses the warper's default
(bilinear).

**Headset check, 2026-11-09:** de-ringed Catmull-Rom in both the warp and the
RealityKit material (the harness's -26% circle error, -15% temporal change)
made no difference the wearer could see, and the headset reached serious
thermal state quickly. A harness gain of this size is not a visible one;
weigh GPU cost first.

`TEST_RUNNER_PCVR_RESIDUAL_MESH_FILTER=catmull-rom-dering` makes the late-mesh
proxy's material read with the same de-ringed Catmull-Rom, to estimate what a
sharper RealityKit material would add (RK's Image 2D node offers only linear
and nearest). The zero-late-miss control then no longer applies and is skipped.
On host-v2 (2026-11-09) it took a further 17.5% off the late-mesh circle error,
10% off its frame-to-frame change and 11-28% off the grids and floor.
