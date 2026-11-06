from pathlib import Path
import json
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

import audio_output_check as check


class AudioOutputCheckTests(unittest.TestCase):
    def test_every_round_includes_all_controls_with_distinct_paths(self):
        cases = check.make_cases(3)
        self.assertEqual(len(cases), 27)
        self.assertEqual(len({case["name"] for case in cases}), 27)
        self.assertEqual({case["kind"] for case in cases},
                         {"normal-a", "normal-b", "left", "right", "no-press",
                          "unmapped", "silent", "loop-stop", "mixed"})
        self.assertEqual(next(case for case in cases if case["kind"] == "no-press")["columns"], [])

    def test_blocked_trial_changes_mapping_but_never_the_owned_references(self):
        with tempfile.TemporaryDirectory() as scratch:
            normal, blocked = [Path(scratch) / name for name in ("normal", "blocked")]
            first = check.stage_fixture(normal, False)
            second = check.stage_fixture(blocked, True)
            for line in (blocked / "keySound").read_text().splitlines():
                self.assertEqual(line.split()[3], "silence.wav")
            self.assertNotEqual(first["staged_sha256"]["keySound"], second["staged_sha256"]["keySound"])
            for path in (normal / "sounds").iterdir():
                self.assertEqual(path.read_bytes(), (blocked / "sounds" / path.name).read_bytes())

    def test_fixture_staging_preserves_existing_evidence(self):
        with tempfile.TemporaryDirectory() as scratch:
            destination = Path(scratch) / "existing"
            destination.mkdir()
            evidence = destination / "keySound"
            evidence.write_text("old evidence")
            with self.assertRaises(FileExistsError):
                check.stage_fixture(destination, True)
            self.assertEqual(evidence.read_text(), "old evidence")

    def test_wrong_generation_or_device_is_rejected_before_device_work(self):
        lease = {"device": "one", "generation": "current", "platform": "ios"}
        check.validate_lease(lease, "one", "current")
        for device, generation in [("other", "current"), ("one", "old")]:
            with self.assertRaises(ValueError):
                check.validate_lease(lease, device, generation)

    def test_cleanup_stops_and_reaps_the_child_it_started(self):
        with tempfile.TemporaryDirectory() as scratch:
            runner = check.Run.__new__(check.Run)
            runner.output = Path(scratch)
            runner.report = {}
            child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
            runner.children = [child]
            try:
                runner.close()
                self.assertIsNotNone(child.poll())
                self.assertTrue((runner.output / "abort").exists())
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)

    def test_capture_peer_receives_target_ready_before_recorder_starts(self):
        """The UI peer must know when discovery and app hashing have ended."""
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            runner = check.Run.__new__(check.Run)
            runner.args = SimpleNamespace(device_tools=root, simulator="owned-device")
            runner.output = root / "round"
            runner.output.mkdir()
            runner.children, runner.commands, runner.results = [], [], []
            runner.report = {"cases": runner.results}
            step = runner.output / "normal-a"
            step.mkdir()
            (step / "input.json").write_text(json.dumps({
                "invoked_ns": 1_600_000_000, "completed_ns": 1_700_000_000}))
            reference = check.ROOT / "test-fixtures/AudioOutput/sounds/pad-a.wav"
            # This peer produces a synthetic receipt, never real device evidence.
            (root / "devices.py").write_text('''import json, sys, wave
from pathlib import Path
output = Path(sys.argv[3])
step = output.parent
if not (step / "target-ready").exists():
    sys.exit("UI peer cannot start its readiness deadline before host preparation ends")
ready = Path(sys.argv[sys.argv.index("--ready") + 1])
ready.write_text(json.dumps({"ready": True, "clock": "CLOCK_UPTIME_RAW",
    "first_frame_monotonic_ns": 1000000000, "notified_monotonic_ns": 1000000000,
    "initial_discard_seconds": 0.1}))
with wave.open(''' + repr(str(reference)) + ''', "rb") as source:
    samples = source.readframes(source.getnframes())
with wave.open(str(output), "wb") as target:
    target.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
    target.writeframes(bytes(33600 * 4) + samples + bytes(110400 * 4))
print(json.dumps({"pid": 123, "complete": True}))
''')
            case = {"name": "normal-a", "kind": "normal-a", "expected": ((440,), (880,))}
            try:
                runner.record(case, step, 123, SimpleNamespace(poll=lambda: None))
                self.assertEqual(runner.results[0]["verdict"]["status"], "pass")
            finally:
                runner.close()


if __name__ == "__main__":
    unittest.main()
