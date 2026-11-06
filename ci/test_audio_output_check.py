from pathlib import Path
import subprocess
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()
