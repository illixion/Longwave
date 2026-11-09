#!/usr/bin/env python3
"""Run the opt-in simulator harness and build an offline, stage/region report."""
import argparse
import base64
import collections
import csv
import datetime
import hashlib
import html
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
FIELDS = ["mae", "p95", "edgeMAE", "gradientError", "temporalErrorChange", "visibleMAE", "hiddenMAE", "hiddenFraction", "outsideFraction"]


def summarize(report):
    groups = collections.defaultdict(list)
    for sample in report["samples"]:
        key = (sample["scenario"], sample["displayHz"], sample["stage"], sample["region"])
        groups[key].append(sample)
    result = {}
    for key, samples in groups.items():
        row = {}
        for field in FIELDS:
            values = [s["metrics"][field] for s in samples if s["metrics"].get(field) is not None]
            row[field] = statistics.mean(values) if values else None
        times = [s["gpuMs"] for s in samples if s.get("gpuMs") is not None]
        row["gpuMs"] = statistics.median(times) if times else None
        row["frames"] = len(samples)
        result[key] = row
    return result


def build_report(out, baseline=None):
    source = out / "residual-report.json"
    report = json.loads(source.read_text())
    if report.get("schema") != 1 or not report.get("samples"):
        raise ValueError("unsupported or empty residual report")
    summary = summarize(report)
    with (out / "metrics.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["scenario", "display_hz", "stage", "region", *FIELDS, "gpu_ms", "frames"])
        for key, row in sorted(summary.items()):
            writer.writerow([*key, *[row[f] for f in FIELDS], row["gpuMs"], row["frames"]])
    comparison = []
    if baseline:
        old = json.loads(Path(baseline).read_text())
        for field in ["schema", "width", "height", "sourceHz", "scenarios", "traces", "motion", "motionSHA256"]:
            if report.get(field) != old.get(field):
                raise ValueError(f"baseline differs in {field}; use matching fixture settings")
        old_summary = summarize(old)
        if set(summary) != set(old_summary):
            raise ValueError("baseline has different region groups")
        for key, old_values in old_summary.items():
            if key not in summary:
                raise ValueError(f"baseline region is missing: {key}")
            for metric in FIELDS:
                before, after = old_values[metric], summary[key][metric]
                if before is not None and after is not None:
                    comparison.append(dict(scenario=key[0], hz=key[1], stage=key[2], region=key[3], metric=metric,
                                           before=before, after=after, delta=after-before))
        (out / "comparison.json").write_text(json.dumps(comparison, indent=2))
    timing_path = out / "timing-report.json"
    timing = json.loads(timing_path.read_text()) if timing_path.exists() else []
    timing_html = "<h2>Virtual timing replay</h2><p>Production timed queue and exact pair selector; synthetic delayed/lost depth and GPU-busy ticks. This is a timing model, not measured headset scheduling.</p><pre>" + html.escape(json.dumps(timing, indent=2)) + "</pre>" if timing else ""
    rows = []
    def value(number):
        return "—" if number is None else f"{number:.6f}"
    for key, row in sorted(summary.items()):
        cells = [*key, *[value(row[f]) for f in FIELDS], value(row["gpuMs"])]
        rows.append("<tr>" + "".join(f"<td>{html.escape(str(c))}</td>" for c in cells) + "</tr>")
    images = []
    for sample in report["samples"]:
        if sample.get("image"):
            image_name = sample["image"]
            if Path(image_name).name != image_name or not image_name.endswith(".png"):
                raise ValueError("image must name a PNG in the report directory")
            encoded = base64.b64encode((out / image_name).read_bytes()).decode("ascii")
            caption = f'{sample["scenario"]} · {sample["displayHz"]} Hz · frame {sample["frame"]} · {sample["stage"]} · {sample["region"]}'
            images.append(f'<figure data-stage="{html.escape(sample["stage"])}" data-region="{html.escape(sample["region"])}">'
                          f'<figcaption>{html.escape(caption)} — truth | stage output | error ×4</figcaption>'
                          f'<img loading="lazy" src="data:image/png;base64,{encoded}" alt="{html.escape(caption)}"></figure>')
    headers = ["scenario", "Hz", "stage", "region", *FIELDS, "GPU ms (Mac)"]
    notes = "".join(f"<li>{html.escape(n)}</li>" for n in report["notes"])
    document = '''<!doctype html><meta charset="utf-8"><title>PCVR residual harness</title>
<style>body{background:#17191d;color:#eee;font:15px system-ui;margin:24px}a{color:#9cf}table{border-collapse:collapse;font:12px ui-monospace}td,th{padding:8px;border:1px solid #444;text-align:right}th{position:sticky;top:0;background:#262a31}figure{margin:24px 0}figure{overflow:auto}img{max-width:none;image-rendering:pixelated}body[data-zoom="2"] img{zoom:2}body[data-zoom="fit"] img{max-width:100%}figcaption{margin-bottom:8px}.scroll{overflow:auto;max-height:480px}select{font:inherit;padding:6px;background:#303640;color:white}li{margin:6px 0}</style>
<h1>PCVR residual harness</h1><p>GPU pipeline measurements on the simulator. No headset required.</p>
<ul>NOTES</ul><p><a href="residual-report.json">Raw JSON</a> · <a href="metrics.csv">CSV</a></p>
<p>Errors use linear RGB in [0,1]; lower is better. Edge MAE uses truth gradients above 0.08. Gradient error scores local shape changes. Temporal error measures change in truth-relative error after landmark centring. Missing temporal values are the first frame. Hidden/outside pixels are scored separately using ray-cast depth. GPU timing scopes are listed above and repeated per region; do not sum region rows.</p>
<h2>Per-region means</h2><div class="scroll"><table><thead><tr>HEADERS</tr></thead><tbody>ROWS</tbody></table></div>
TIMING<h2>Native-pixel crops</h2><label>Zoom <select onchange="document.body.dataset.zoom=this.value"><option value="1">1× native</option><option value="2">2×</option><option value="fit">Fit</option></select></label><label>Stage <select id="stage"><option value="">All</option><option>sampling</option><option>warp</option><option>late-mesh-proxy</option></select></label>
<label>Region <select id="region"><option value="">All</option><option>circle</option><option>left-grid</option><option>right-grid</option><option>floor</option></select></label>IMAGES
<script>const stage=document.getElementById('stage'),region=document.getElementById('region');function filter(){for(const f of document.querySelectorAll('figure'))f.hidden=(stage.value&&f.dataset.stage!==stage.value)||(region.value&&f.dataset.region!==region.value)}stage.onchange=region.onchange=filter;</script>'''
    document = document.replace("NOTES", notes).replace("HEADERS", "".join(f"<th>{html.escape(h)}</th>" for h in headers))
    document = document.replace("ROWS", "".join(rows)).replace("IMAGES", "".join(images)).replace("TIMING", timing_html)
    (out / "index.html").write_text(document)
    return len(summary), len(comparison)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("/private/tmp") / ("pcvr-residuals-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S")))
    parser.add_argument("--profile", choices=["smoke", "full"], default="smoke")
    parser.add_argument("--frames", type=int)
    parser.add_argument("--trajectory", type=Path, help="existing V3PoseRecorder JSON; never captures live device data")
    parser.add_argument("--simulator", help="visionOS simulator UDID; defaults to the first available Apple Vision Pro")
    parser.add_argument("--derived-data", type=Path, default=Path("/private/tmp/longwave-residual-derived-data"))
    parser.add_argument("--compare", type=Path, help="baseline residual-report.json with identical fixture settings")
    parser.add_argument("--report-only", action="store_true", help="regenerate HTML/CSV from an existing output directory")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if not args.report_only:
        if (out / "residual-report.json").exists():
            parser.error("output already contains a run; choose a fresh directory or --report-only")
        frames = args.frames or (8 if args.profile == "full" else 3)
        if not 2 <= frames <= 24:
            parser.error("--frames must be 2...24")
        devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
        eligible = [d for runtime, group in devices.items() if "xrOS" in runtime for d in group if "Vision Pro" in d["name"]]
        eligible.sort(key=lambda d: d["state"] != "Booted")
        device = next((d for d in eligible if d["udid"] == args.simulator), None) if args.simulator else next(iter(eligible), None)
        if not device:
            parser.error("no matching available Apple Vision Pro simulator")
        if device["state"] != "Booted":
            subprocess.run(["xcrun", "simctl", "boot", device["udid"]], check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"], check=True)
        env = os.environ.copy()
        env.update(TEST_RUNNER_PCVR_BENCH=str(out), TEST_RUNNER_PCVR_RESIDUAL_PROFILE=args.profile,
                   TEST_RUNNER_PCVR_RESIDUAL_FRAMES=str(frames))
        env.pop("TEST_RUNNER_PCVR_BENCH_TRAJECTORY", None)
        if args.trajectory:
            env["TEST_RUNNER_PCVR_BENCH_TRAJECTORY"] = str(args.trajectory.resolve(strict=True))
        command = ["xcodebuild", "test", "-project", "Longwave.xcodeproj", "-scheme", "LongwaveTests",
                   "-destination", f'platform=visionOS Simulator,id={device["udid"]}', "-derivedDataPath", str(args.derived_data.resolve()),
                   "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) FOVEATED_ENABLED", "XROS_DEPLOYMENT_TARGET=26.4",
                   "-only-testing:LongwaveTests/PCVRWarpBenchTests/testResidualStages",
                   "-only-testing:LongwaveTests/PCVRWarpBenchTests/testResidualTimingReplay", "-collect-test-diagnostics", "never"]
        metadata = dict(commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                        dirty=bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=REPO)),
                        profile=args.profile, frames=frames, simulator=device["udid"], command=command)
        if args.trajectory:
            metadata["trajectorySHA256"] = hashlib.sha256(args.trajectory.read_bytes()).hexdigest()
        (out / "run.json").write_text(json.dumps(metadata, indent=2))
        print(f"Running {args.profile}, {frames} frames per case. Log: {out / 'xcodebuild.log'}", flush=True)
        with (out / "xcodebuild.log").open("w") as log:
            result = subprocess.run(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            print(f"Harness failed; inspect {out / 'xcodebuild.log'}", file=sys.stderr)
            return result.returncode
        report_path = out / "residual-report.json"
        report = json.loads(report_path.read_text())
        report["motionSHA256"] = metadata.get("trajectorySHA256", "synthetic-sine-v1")
        report_path.write_text(json.dumps(report, indent=2))
    groups, differences = build_report(out, args.compare)
    print(f"Report: {out / 'index.html'} ({groups} region groups; {differences} baseline comparisons)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
