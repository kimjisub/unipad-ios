"""Release commands must exercise every required suite and reject incomplete evidence."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from release_checks import (ReleaseChecks, required_midi_tests, required_ui_tests, required_unit_suites, screen_part,
                            verify_results)


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

    def test_requires_each_unit_suite_by_name(self):
        summary = dict(totalTestCount=2, passedTests=2, failedTests=0, skippedTests=0)
        case = {"nodeType": "Test Case", "nodeIdentifier": "LedRunnerTests/one()", "result": "Passed"}
        tree = {"testNodes": [{"nodeType": "Unit test bundle", "name": "unipadTests", "children": [
            {"nodeType": "Test Suite", "name": "LedRunnerTests", "result": "Passed", "children": [case]},
            {"nodeType": "Test Suite", "name": "PlayLayoutTests", "result": "Passed", "children": []}]}]}
        verify_results(summary, tree, [], ["LedRunnerTests"])
        for suites in [["PlayLayoutTests"], ["MainListReadTests"]]:
            with self.subTest(suites=suites), self.assertRaises(ValueError):
                verify_results(summary, tree, [], suites)

    def test_unit_suites_come_from_the_iphone_release_plan(self):
        suites = required_unit_suites("ReleaseFeatures")
        for suite in ["MainListReadTests", "LedRunnerTests", "PlayUsageRecordTests", "MultiTouchPlayTests"]:
            self.assertIn(suite, suites)
        self.assertEqual(required_unit_suites("IPadReleaseFeatures"), [])

    def test_unit_stage_is_iphone_only(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("UNIPAD_TEST_TMPDIR")) as folder:
            command = [sys.executable, str(ROOT / "ci/release_checks.py"), "--device", "ipad",
                       "--stage", "unit", "--simulator", "not-acquired",
                       "--output", folder + "/results", "--derived-data", folder + "/dd"]
            result = subprocess.run(command, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("iPad checks have only the screen stage", result.stderr)

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

    def test_full_screen_stage_verifies_the_unit_suites_but_parts_leave_them_to_the_unit_stage(self):
        suites = required_unit_suites("ReleaseFeatures")
        self.exercise("iphone", stage="screen")
        self.assertEqual(self.checked_bundles[0].args[2], suites)
        for index in range(1, 4):
            calls = self.exercise("iphone", stage="screen", screen_part=(index, 3))
            self.assertFalse([x for x in calls[0][1] if x.startswith("-only-testing:unipadTests")])
            self.assertEqual(self.checked_bundles[0].args[2], [])
        calls = self.exercise("iphone", stage="unit")
        self.assertEqual([x[0] for x in calls], ["unit"])
        self.assertEqual(calls[0][1][-3:], ["-testPlan", "ReleaseFeatures", "-only-testing:unipadTests"])
        self.assertEqual(calls[0][2]["env"]["UNIPAD_UI_TEST_CONFIGURATION"], "Release")
        self.assertEqual(self.checked_bundles[0].args[1:], ([], suites))

    def test_screen_parts_cannot_create_empty_successful_runs(self):
        with self.assertRaises(ValueError):
            self.exercise("ipad", stage="screen", screen_group="ipad", screen_part=(1, 24))


STOP_DRIVER = """
import argparse, json, signal, subprocess, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import release_checks
release_checks.STOP_GRACE_SECONDS = float(sys.argv[3])
folder = Path(sys.argv[2])
args = argparse.Namespace(simulator="none", device="iphone", output=folder / "results", derived_data=folder / "dd")
run = release_checks.ReleaseChecks(args)
release_checks.install_stop_handlers(run)
try:
    run.stage("child", json.loads(sys.argv[4]))
    print("finished")
except Exception as error:
    print(type(error).__name__, error)
"""

# Starts, then on SIGINT (when it honours it) cleans up for a moment and exits 0.
STOP_CHILD = """
import signal, sys, time
from pathlib import Path
if "{mode}" == "honour":
    signal.signal(signal.SIGINT, lambda *_: (time.sleep(0.5), sys.exit(0)))
else:
    signal.signal(signal.SIGINT, signal.SIG_IGN)
Path(sys.argv[1]).touch()
time.sleep(60)
"""

# Like ci/ui-tests.sh: stop traps that exit, an EXIT cleanup, and a script run in the foreground.
STOP_OUTER_SCRIPT = """
folder=$1
trap "touch $folder/outer-cleaned" EXIT
trap 'exit 130' INT TERM HUP
/bin/zsh -c "$2" inner $folder
"""

# Like ci/host-keys.sh and ci/midi-input-tests.sh: a background helper (here one that ignores
# stops) and the test tool (xcodebuild) in the foreground, which zsh waits for before its traps.
STOP_INNER_SCRIPT = """
folder=$1
trap "touch $folder/inner-cleaned" EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
/bin/sh -c 'trap "" INT TERM HUP; echo $$ > "$1/helper.pid"; exec sleep 60' helper $folder &
/bin/sh -c 'while [ ! -s "$1/helper.pid" ]; do sleep 0.05; done
echo $$ > "$1/tool.pid"; touch "$1/started"; exec sleep 60' tool $folder
"""


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A process that has ended but is not yet reaped by its new parent still answers.
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], text=True, capture_output=True).stdout
    return bool(state.strip()) and not state.strip().startswith("Z")


class StopRequestTests(unittest.TestCase):
    def interrupt(self, mode, grace, sig=signal.SIGINT):
        return self.interrupt_command(lambda folder: [sys.executable, "-c", STOP_CHILD.replace("{mode}", mode),
                                                      str(folder / "started")], grace, sig)

    def interrupt_command(self, command, grace, sig, inspect=None):
        with tempfile.TemporaryDirectory(dir=os.environ.get("UNIPAD_TEST_TMPDIR")) as name:
            folder = Path(name)
            driver = subprocess.Popen([sys.executable, "-c", STOP_DRIVER, str(ROOT / "ci"), name, str(grace),
                                       json.dumps(command(folder))], text=True, stdout=subprocess.PIPE)
            started = folder / "started"
            for _ in range(200):
                if started.exists() or driver.poll() is not None:
                    break
                time.sleep(0.05)
            self.assertTrue(started.exists())
            began = time.monotonic()
            driver.send_signal(sig)
            try:
                output, _ = driver.communicate(timeout=grace + 15)
            finally:
                if driver.poll() is None:
                    driver.kill()
            seconds = time.monotonic() - began
            stage = json.loads((folder / "results/result.json").read_text())["stages"][0]
            if inspect:
                inspect(folder)
            return output, stage, seconds

    def test_a_stop_reaches_the_stage_and_is_reported_as_an_interruption(self):
        output, stage, seconds = self.interrupt("honour", grace=45)
        self.assertIn("InterruptedError interrupted by signal 2", output)
        self.assertEqual(stage["exit_code"], 0)
        self.assertLess(seconds, 10)

    def test_a_stage_ignoring_the_stop_is_ended_after_the_grace_period(self):
        output, stage, seconds = self.interrupt("ignore", grace=1)
        self.assertIn("InterruptedError interrupted by signal 2", output)
        self.assertEqual(stage["exit_code"], -signal.SIGKILL)
        self.assertLess(seconds, 10)


    def test_a_stop_reaches_the_tool_under_the_stage_script_and_lets_both_scripts_clean_up(self):
        for sig in [signal.SIGTERM, signal.SIGHUP]:
            with self.subTest(signal=sig.name):
                seen = {}

                def inspect(folder):
                    pids = {name: int((folder / f"{name}.pid").read_text()) for name in ["tool", "helper"]}
                    try:
                        deadline = time.monotonic() + 5
                        while any(alive(pid) for pid in pids.values()) and time.monotonic() < deadline:
                            time.sleep(0.1)
                        seen["alive"] = [name for name, pid in pids.items() if alive(pid)]
                        seen["cleaned"] = sorted(path.name for path in folder.glob("*-cleaned"))
                    finally:
                        for pid in pids.values():
                            try:
                                os.kill(pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass

                output, stage, seconds = self.interrupt_command(
                    lambda folder: ["/bin/zsh", "-c", STOP_OUTER_SCRIPT, "outer", str(folder), STOP_INNER_SCRIPT],
                    grace=10, sig=sig, inspect=inspect)
                self.assertIn(f"InterruptedError interrupted by signal {int(sig)}", output)
                self.assertEqual(seen["alive"], [])
                self.assertEqual(seen["cleaned"], ["inner-cleaned", "outer-cleaned"])
                # The outer script ended through its own trap, not the kill after the grace period.
                self.assertEqual(stage["exit_code"], 130)
                self.assertLess(seconds, 10)

    def test_a_stop_while_the_stage_starts_still_stops_it(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("UNIPAD_TEST_TMPDIR")) as folder:
            run = ReleaseChecks(argparse.Namespace(simulator="none", device="iphone", output=Path(folder) / "results",
                                                   derived_data=Path(folder) / "dd"))
            started = []
            real_popen = subprocess.Popen

            def popen(*args, **kwargs):
                started.append(real_popen(*args, **kwargs))
                # The signal arrives after the stage's process exists but before the runner keeps it.
                run.request_stop(signal.SIGTERM)
                return started[-1]

            try:
                with patch("release_checks.subprocess.Popen", popen), self.assertRaises(InterruptedError):
                    run.stage("child", [sys.executable, "-c", "import time; time.sleep(60)"])
                self.assertIsNotNone(started[0].poll())
                self.assertEqual(run.report["stages"][0]["exit_code"], -signal.SIGTERM)
            finally:
                for child in started:
                    if child.poll() is None:
                        child.kill()
                        child.wait()


if __name__ == "__main__":
    unittest.main()
