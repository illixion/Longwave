import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("pcvr_residual_report", Path(__file__).with_name("run.py"))
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


def fixture():
    metrics = {key: 0.0 for key in reporter.FIELDS}
    metrics["temporalErrorChange"] = None
    sample = dict(scenario="fixture", displayHz=60, frame=0, stage="warp", region="circle", metrics=metrics, gpuMs=2.0, image=None)
    return dict(schema=1, width=10, height=10, sourceHz=60, scenarios=[], traces=[], motion="synthetic-sine-v1",
                motionSHA256="synthetic-sine-v1", notes=["simulator only"], samples=[sample])


class ReportTests(unittest.TestCase):
    def test_region_and_stage_do_not_get_averaged_together(self):
        report = fixture()
        other = copy.deepcopy(report["samples"][0])
        other.update(region="floor", stage="sampling")
        other["metrics"]["mae"] = 1.0
        report["samples"].append(other)
        summary = reporter.summarize(report)
        self.assertEqual(summary[("fixture", 60, "warp", "circle")]["mae"], 0)
        self.assertEqual(summary[("fixture", 60, "sampling", "floor")]["mae"], 1)

    def test_identical_baseline_has_zero_deltas(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            raw = out / "residual-report.json"
            raw.write_text(json.dumps(fixture()))
            groups, comparisons = reporter.build_report(out, raw)
            self.assertEqual(groups, 1)
            self.assertGreater(comparisons, 0)
            self.assertTrue(all(row["delta"] == 0 for row in json.loads((out / "comparison.json").read_text())))
            self.assertTrue((out / "metrics.csv").exists())
            self.assertIn("truth-relative", (out / "index.html").read_text())

    def test_different_motion_is_not_a_valid_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            current, old = fixture(), fixture()
            old["motionSHA256"] = "another-recording"
            (out / "residual-report.json").write_text(json.dumps(current))
            baseline = out / "baseline.json"
            baseline.write_text(json.dumps(old))
            with self.assertRaisesRegex(ValueError, "motionSHA256"):
                reporter.build_report(out, baseline)

    def test_images_are_embedded_and_cannot_escape_the_output_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            report = fixture()
            report["samples"][0]["image"] = "crop.png"
            (out / "crop.png").write_bytes(b"PNG fixture bytes")
            raw = out / "residual-report.json"
            raw.write_text(json.dumps(report))
            reporter.build_report(out)
            self.assertIn("data:image/png;base64,", (out / "index.html").read_text())
            report["samples"][0]["image"] = "../private.png"
            raw.write_text(json.dumps(report))
            with self.assertRaisesRegex(ValueError, "image must name a PNG"):
                reporter.build_report(out)

    def test_metadata_is_escaped_in_html(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            report = fixture()
            report["samples"][0]["scenario"] = "<script>untrusted</script>"
            (out / "residual-report.json").write_text(json.dumps(report))
            reporter.build_report(out)
            html = (out / "index.html").read_text()
            self.assertNotIn("<script>untrusted</script>", html)
            self.assertIn("&lt;script&gt;untrusted&lt;/script&gt;", html)


if __name__ == "__main__":
    unittest.main()
