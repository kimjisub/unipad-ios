from pathlib import Path
import json
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import audio_output_check as check


class AudioOutputCheckTests(unittest.TestCase):
    def test_preparation_errors_exit_unverified_and_preserve_evidence(self):
        for existing in (True, False):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                output = root / "round"
                recorder = root / "recorder"
                if existing:
                    output.mkdir()
                    (output / "summary.json").write_text("previous evidence")
                    recorder.write_bytes(b"recorder")
                command = [sys.executable, str(check.ROOT / "ci/audio_output_check.py"),
                           "--simulator", "unused", "--generation", "unused",
                           "--device-tools", str(root), "--recorder-binary", str(recorder),
                           "--derived-data", str(root / "dd"), "--output", str(output)]
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2, result.stderr)
                if existing:
                    self.assertEqual((output / "summary.json").read_text(), "previous evidence")
                reports = [json.loads(path.read_text()) for path in root.glob("*/summary.json")
                           if path.parent != output or not existing]
                self.assertEqual(len(reports), 1)
                self.assertEqual(reports[0]["status"], "environment_unverified")
                self.assertIn("error", reports[0])
                self.assertEqual(reports[0]["cases"], [])

    def test_unexpected_errors_cannot_look_like_an_output_mismatch(self):
        for error in (KeyError("missing field"), TypeError("wrong field"),
                      subprocess.CalledProcessError(1, ["probe"])):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as scratch:
                output = Path(scratch) / "round"
                recorder = Path(scratch) / "recorder"
                recorder.write_bytes(b"recorder")
                args = ["check", "--simulator", "unused", "--generation", "unused",
                        "--device-tools", scratch, "--recorder-binary", str(recorder),
                        "--derived-data", scratch, "--output", str(output)]
                with patch.object(sys, "argv", args), patch.object(check.Run, "run", side_effect=error):
                    self.assertEqual(check.main(), 2)
                reports = list(Path(scratch).glob("*/summary.json"))
                self.assertEqual(len(reports), 1)
                report = json.loads(reports[0].read_text())
                self.assertEqual(report["status"], "environment_unverified")
                self.assertIn(str(error), report["error"])

    def test_control_reuses_the_verified_test_build_without_relinking_the_app(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            recorder = root / "recorder"
            recorder.write_bytes(b"owned recorder")
            args = SimpleNamespace(output=root / "round", recorder_binary=recorder,
                                   simulator="owned", generation="current", device_tools=root,
                                   derived_data=root / "dd", block_playback=True, repeats=1,
                                   reuse_build=True, verified_capture=root / "positive.json")
            runner = check.Run(args)
            runner.device = Mock(return_value=json.dumps(
                {"platform": "ios", "device": "owned", "generation": "current"}))
            runner.command = Mock(side_effect=lambda command, **_: json.dumps({"devices": {}})
                                  if command[:4] == ["xcrun", "simctl", "list", "devices"] else "")
            runner.start = Mock(side_effect=RuntimeError("test command captured"))
            with self.assertRaisesRegex(RuntimeError, "test command captured"):
                runner.run()
            self.assertFalse(any("build" in call.args[0] for call in runner.command.call_args_list),
                             "a control must not relink the previously verified app")
            self.assertEqual(runner.start.call_args.args[0][4], "test-without-building")

    def test_app_identity_includes_debug_code_with_an_unchanged_launcher(self):
        with tempfile.TemporaryDirectory() as scratch:
            app = Path(scratch) / "unipad.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "unipad"}))
            (app / "unipad").write_bytes(b"unchanged debug launcher")
            code = app / "unipad.debug.dylib"
            code.write_bytes(b"first audio implementation")
            before = check.app_identity(app)
            code.write_bytes(b"different audio implementation")
            after = check.app_identity(app)
            self.assertNotEqual(before["sha256"], after["sha256"],
                                "the same launcher must not identify different app code")

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

    def test_incomplete_capture_is_preserved_without_assessing_the_app(self):
        for code, detail in [(5, {"complete": False}),
                             (0, {"complete": True, "discontinuities": [{"missing_frames": 512}]}),
                             (0, {"complete": True, "packet_log_overflow": True})]:
            with self.subTest(code=code, detail=detail), tempfile.TemporaryDirectory() as scratch:
                root = Path(scratch)
                runner = check.Run.__new__(check.Run)
                runner.args = SimpleNamespace(device_tools=root, simulator="owned-device")
                runner.output = root
                runner.children, runner.commands, runner.results = [], [], []
                runner.report = {"cases": runner.results}
                step = root / "normal-a"
                step.mkdir()
                summary = {"pid": 123, **detail}

                def start(command, log):
                    log.write(json.dumps(summary) + "\n")
                    log.flush()
                    return SimpleNamespace(returncode=code, wait=lambda timeout: None)

                runner.start = start
                runner.wait = lambda *args: {"ready": True}
                case = {"name": "normal-a", "kind": "normal-a", "expected": ((440,), (880,))}
                with patch.object(check, "assess", return_value={"status": "pass", "reason": "synthetic"}) as assess:
                    with self.assertRaisesRegex(RuntimeError, "recording incomplete"):
                        runner.record(case, step, 123, None)
                    assess.assert_not_called()
                saved = json.loads((root / "summary.json").read_text())
                self.assertEqual(saved["cases"][0]["capture"], summary)
                self.assertEqual(saved["cases"][0]["recorder_exit"], code)
                self.assertEqual(saved["cases"][0]["verdict"]["status"], "environment_unverified")

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
            # Like the real recorder, it publishes its readiness record whole under the final name,
            # and pauses mid-write so a reader of the unfinished record fails every time.
            (root / "devices.py").write_text('''import json, sys, time, wave
from pathlib import Path
output = Path(sys.argv[3])
step = output.parent
if not (step / "target-ready").exists():
    sys.exit("UI peer cannot start its readiness deadline before host preparation ends")
ready = Path(sys.argv[sys.argv.index("--ready") + 1])
record = json.dumps({"ready": True, "clock": "CLOCK_UPTIME_RAW",
    "first_frame_monotonic_ns": 1000000000, "notified_monotonic_ns": 1000000000,
    "initial_discard_seconds": 0.1})
unfinished = ready.with_name(ready.name + ".partial")
with unfinished.open("w") as file:
    file.write(record[:len(record) // 2])
    file.flush()
    time.sleep(0.2)
    file.write(record[len(record) // 2:])
unfinished.replace(ready)
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
