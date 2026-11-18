"""Release commands must exercise every required suite and reject incomplete evidence."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from release_checks import ReleaseChecks, required_midi_tests, required_ui_tests, screen_part, verify_results


ROOT = Path(__file__).resolve().parents[1]


class ResultTests(unittest.TestCase):
    def test_screen_part_requires_a_valid_one_based_index_and_count(self):
        self.assertEqual(screen_part("1/3"), (1, 3))
        self.assertEqual(screen_part("1/1"), (1, 1))
        for value in ["0/3", "4/3", "1/0", "-1/3", "1", "a/b", "1/2/3"]:
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                screen_part(value)

    def test_screen_part_cannot_run_other_stages(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("UNIPAD_TEST_TMPDIR")) as folder:
            command = [sys.executable, str(ROOT / "ci/release_checks.py"), "--device", "iphone",
                       "--stage", "midi", "--screen-part", "1/3", "--simulator", "not-acquired",
                       "--output", folder + "/results", "--derived-data", folder + "/dd"]
            result = subprocess.run(command, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--screen-part requires --stage screen", result.stderr)

    def test_requires_each_selected_test_even_when_the_summary_is_green(self):
        summary = dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
        tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "Suite/testOne()", "result": "Passed"}]}
        verify_results(summary, tree, ["Suite/testOne()"])
        for required in [["Suite/testTwo()"], ["OtherSuite/testOne()"]]:
            with self.assertRaises(ValueError):
                verify_results(summary, tree, required)

    def test_rejects_skipped_failed_empty_and_incomplete_results(self):
        for summary in [dict(totalTestCount=1, passedTests=0, failedTests=0, skippedTests=1),
                        dict(totalTestCount=1, passedTests=0, failedTests=1, skippedTests=0),
                        dict(totalTestCount=0, passedTests=0, failedTests=0, skippedTests=0),
                        dict(totalTestCount=2, passedTests=1, failedTests=0, skippedTests=0), {}]:
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                verify_results(summary, {}, [])

    def test_green_summary_cannot_hide_a_skipped_or_expected_failure_case(self):
        summary = dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
        for result in ["Skipped", "Expected Failure", "Unknown"]:
            tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "Suite/testOne()", "result": result}]}
            with self.subTest(result=result), self.assertRaises(ValueError):
                verify_results(summary, tree, ["Suite/testOne()"])

    def test_midi_manifest_includes_the_device_selection_and_reconnect_cases(self):
        required = required_midi_tests()
        self.assertIn("PlayUsageRecordTests/MidiDeviceSelectionTests/firstConnectionPrefersLaunchpadRegardlessOfSourceOrder", required)
        self.assertIn("PlayUsageRecordTests/MidiInputPathTests/virtualDeviceReportsAFailedCommand", required)
        self.assertIn("VirtualMidiPlayScreenUITests/testLaunchpadInputAndLightsReturnAfterUnpluggingDuringPlay", required)

    def test_a_failed_parameter_or_repetition_is_not_hidden_by_a_pass(self):
        summary = dict(totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0)
        for kind in ["Arguments", "Repetition", "Test Case Run"]:
            tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": "Suite/one(kind:)",
                                   "result": "Passed", "children": [{"nodeType": kind, "result": "Skipped"}]}]}
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                verify_results(summary, tree, ["Suite/one"])

    def test_ipad_plan_includes_all_release_screens_and_ipad_only_checks(self):
        required = required_ui_tests("IPadReleaseFeatures")
        self.assertTrue(set(required_ui_tests("ReleaseFeatures")) <= set(required))
        self.assertEqual(len([x for x in required if x.startswith("WindowControlsBackButtonTests/")]), 12)
        self.assertEqual(len([x for x in required if x.startswith("StoreBackButtonStatusBarTests/")]), 9)
        self.assertIn("PlayInputEdgeUITests/testPointerClicksDragsAndChangesChain()", required)
        self.assertIn("PlayPadLayoutTests/testPadsAreCentredAndReachable()", required)


class ReleaseRunnerTests(unittest.TestCase):
    def exercise(self, family, failed_stage=None, **options):
        with tempfile.TemporaryDirectory(dir=os.environ.get("UNIPAD_TEST_TMPDIR")) as folder:
            args = argparse.Namespace(simulator="leased-device", device=family,
                                      output=Path(folder) / "results", derived_data=Path(folder) / "dd",
                                      stage=options.get("stage", "all"), screen_group=options.get("screen_group", "all"),
                                      screen_part=options.get("screen_part"))
            run = ReleaseChecks(args)
            self.report = run.report
            calls = []

            def stage(name, command, **kwargs):
                calls.append((name, command, kwargs))
                if name == failed_stage:
                    raise subprocess.CalledProcessError(65, command)

            with patch.object(run, "stage", side_effect=stage), patch.object(run, "check_bundle") as checked:
                if failed_stage:
                    with self.assertRaises(subprocess.CalledProcessError):
                        run.execute()
                else:
                    run.execute()
                self.checked_bundles = checked.call_args_list
            return calls

    def test_phone_runs_release_screens_midi_selection_screen_and_roundtrip(self):
        calls = self.exercise("iphone")
        self.assertEqual([x[0] for x in calls], ["screen", "midi-build", "midi", "roundtrip"])
        self.assertIn("ReleaseFeatures", calls[0][1])
        midi = calls[2][1]
        self.assertIn("unipadTests/PlayUsageRecordTests/MidiDeviceSelectionTests", midi)
        self.assertIn("unipadUITests/VirtualMidiPlayScreenUITests", midi)
        self.assertIn("ci/virtual_launchpad_roundtrip.py", calls[3][1])

    def test_ipad_runs_its_release_plan_with_ipad_exclusions_removed(self):
        calls = self.exercise("ipad")
        self.assertEqual([x[0] for x in calls], ["screen"])
        self.assertIn("IPadReleaseFeatures", calls[0][1])
        self.assertEqual(calls[0][2]["env"]["UNIPAD_UI_TEST_DEVICE"], "ipad")

    def test_a_failed_stage_stops_the_release_command(self):
        for stage in ["screen", "midi-build", "midi", "roundtrip"]:
            calls = self.exercise("iphone", stage)
            self.assertEqual(calls[-1][0], stage)

    def test_stages_can_run_separately_without_repeating_other_stages(self):
        for stage, expected in [("screen", ["screen"]), ("midi", ["midi-build", "midi"]),
                                ("roundtrip", ["roundtrip"])]:
            with self.subTest(stage=stage):
                calls = self.exercise("iphone", stage=stage)
                self.assertEqual([x[0] for x in calls], expected)

    def test_ipad_groups_cover_every_screen_once(self):
        required = set(required_ui_tests("IPadReleaseFeatures"))
        shared = set(required_ui_tests("ReleaseFeatures"))
        observed = []
        for group, expected in [("shared", shared), ("ipad", required - shared)]:
            calls = self.exercise("ipad", screen_group=group)
            selected = {x.removeprefix("-only-testing:unipadUITests/") for x in calls[0][1]
                        if x.startswith("-only-testing:unipadUITests/")}
            self.assertEqual(selected, {x.split("(", 1)[0] for x in expected})
            self.assertEqual(set(self.checked_bundles[0].args[1]), expected)
            observed.append(selected)
        self.assertFalse(observed[0] & observed[1])
        self.assertEqual(observed[0] | observed[1], {x.split("(", 1)[0] for x in required})

    def test_screen_parts_cover_each_group_once_and_verify_the_selected_tests(self):
        for family, group, plan in [("iphone", "all", "ReleaseFeatures"),
                                    ("ipad", "shared", "ReleaseFeatures"),
                                    ("ipad", "ipad", "IPadReleaseFeatures")]:
            required = set(required_ui_tests(plan))
            if group == "ipad":
                required -= set(required_ui_tests("ReleaseFeatures"))
            observed = set()
            for index in range(1, 4):
                calls = self.exercise(family, stage="screen", screen_group=group, screen_part=(index, 3))
                selected = {x.removeprefix("-only-testing:unipadUITests/") for x in calls[0][1]
                            if x.startswith("-only-testing:unipadUITests/")}
                self.assertTrue(selected)
                self.assertEqual(self.report["screen_part"], (index, 3))
                self.assertFalse(observed & selected)
                self.assertEqual(selected, {x.split("(", 1)[0] for x in self.checked_bundles[0].args[1]})
                observed |= selected
            self.assertEqual(observed, {x.split("(", 1)[0] for x in required})

    def test_screen_parts_cannot_create_empty_successful_runs(self):
        with self.assertRaises(ValueError):
            self.exercise("ipad", stage="screen", screen_group="ipad", screen_part=(1, 24))


if __name__ == "__main__":
    unittest.main()
