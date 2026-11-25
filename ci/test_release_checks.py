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

from release_checks import (MIDI_SUITES, ReleaseChecks, midi_suite_tests, required_midi_tests, required_ui_tests,
                            required_unit_suites, screen_part, verify_results)


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

    def test_midi_manifest_counts_every_source_test_declaration(self):
        required = required_midi_tests()
        for selection in MIDI_SUITES:
            target, suite = selection.split("/", 1)
            source = (ROOT / target / f"{suite.split('/')[-1]}.swift").read_text()
            declaration = "func test" if target == "unipadUITests" else "@Test"
            count = sum(declaration in line for line in source.splitlines()
                        if not line.lstrip().startswith("//"))
            with self.subTest(suite=suite):
                self.assertGreater(count, 0)
                self.assertEqual(len([name for name in required if name.startswith(suite + "/")]), count)
        self.assertIn("PlayUsageRecordTests/MidiDeviceSelectionTests/recognisedFirmwareIsReported", required)

    def test_connection_status_cases_cannot_disappear_from_a_green_midi_result(self):
        required = required_midi_tests()
        status = [name for name in required if name.startswith("VirtualMidiConnectionStatusUITests/")]
        self.assertEqual(len(status), 7)
        self.assertEqual(set(status), set(midi_suite_tests("unipadUITests/VirtualMidiConnectionStatusUITests")))
        for missing in [status, *[[name] for name in status]]:
            with self.subTest(missing=missing):
                nodes = [{"nodeType": "Test Case", "nodeIdentifier": name, "result": "Passed"}
                         for name in required if name not in missing]
                summary = dict(totalTestCount=len(nodes), passedTests=len(nodes), failedTests=0, skippedTests=0)
                with self.assertRaisesRegex(ValueError, "required test did not run"):
                    verify_results(summary, {"testNodes": nodes}, required)

    def test_midi_source_names_include_multiline_attributes_and_exclude_ui_helpers_and_comments(self):
        sources = {
            "unipadTests": ("""
                @Test func plain() {}
                @MainActor @Test func attributed() {}
                @available(iOS 17.0, *) @Test func available() {}
                @Test nonisolated func nonisolatedTest() {}
                @Test(arguments: [
                    (1, 2),
                    (3, 4)
                ])
                func parameterised(value: (Int, Int)) {}
                // @Test func commentedOut() {}
                /* @Test func blockCommentedOut() {} */
                @Test("func decoy()") func namedAfterDescription() {}
                func helper() {}
            """, ["Suite/plain", "Suite/attributed", "Suite/available", "Suite/nonisolatedTest",
                   "Suite/parameterised", "Suite/namedAfterDescription"]),
            "unipadUITests": ("""
                func testReal() throws {}
                func testAsync() async throws {}
                @MainActor func testAttributed() throws {}
                @available(iOS 17.0, *) func testAvailable() {}
                override func testOverridden() {}
                nonisolated(unsafe) func testNonisolated() {}
                // func testCommentedOut() {}
                /* func testBlockCommentedOut() {} */
                let text = "func testInAString() {}"
                func testHelper(value: Int) {}
                func helper() {}
            """, ["Suite/testReal", "Suite/testAsync", "Suite/testAttributed", "Suite/testAvailable",
                   "Suite/testOverridden", "Suite/testNonisolated"]),
        }
        with tempfile.TemporaryDirectory(dir=os.environ.get("UNIPAD_TEST_TMPDIR")) as folder:
            root = Path(folder)
            for target, (source, expected) in sources.items():
                with self.subTest(target=target):
                    (root / target).mkdir()
                    path = root / target / "Suite.swift"
                    path.write_text(source)
                    with patch("release_checks.ROOT", root):
                        self.assertEqual(midi_suite_tests(target + "/Suite"), expected)
                    path.write_text("// func testCommentedOut() {}\nfunc testHelper(value: Int) {}\n")
                    with patch("release_checks.ROOT", root), self.assertRaisesRegex(ValueError, "has no tests"):
                        midi_suite_tests(target + "/Suite")

    def test_midi_reader_accepts_attributed_declarations_used_in_the_repository(self):
        examples = {
            "unipadUITests/PlayChainLayoutTests": "PlayChainLayoutTests/testTallPackLogoInNormalMode",
            "unipadUITests/AppStoreUpdateUITests": "AppStoreUpdateUITests/testNewVersionKeepsExistingPromptAndPackPlayback",
            "unipadTests/MidiConnectionHelpTests": "MidiConnectionHelpTests/readingHelpKeepsSelectionPreferencesAndDriver",
        }
        for selection, expected in examples.items():
            with self.subTest(selection=selection):
                self.assertIn(expected, midi_suite_tests(selection))

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

    def test_release_plans_require_the_theme_option_screens(self):
        expected = {"PlayOptionThemeUITests/" + method + "()" for method in (
            "testDefaultThemeKeepsOrange", "testThemeWithoutOptionAccentKeepsOrange",
            "testExplicitOptionAccentColorsEnabledSwitch")}
        for plan in ("ReleaseFeatures", "IPadReleaseFeatures"):
            required = required_ui_tests(plan)
            with self.subTest(plan=plan):
                self.assertTrue(expected <= set(required))
                nodes = [{"nodeType": "Test Case", "nodeIdentifier": name, "result": "Passed"}
                         for name in required if name not in expected]
                summary = dict(totalTestCount=len(nodes), passedTests=len(nodes), failedTests=0, skippedTests=0)
                with self.assertRaisesRegex(ValueError, "required test did not run"):
                    verify_results(summary, {"testNodes": nodes}, required)

    def test_release_unit_plan_requires_the_new_regression_suites(self):
        expected = {"PlayOptionThemeTests", "ThemeGuideLinkTests", "ThemeMetadataTests",
                    "StatusBarOverlapTests", "ReleaseTestSoundLoadGateTests"}
        required = required_unit_suites("ReleaseFeatures")
        self.assertTrue(expected <= set(required))
        for missing in expected:
            nodes = [{"nodeType": "Test Suite", "name": name, "result": "Passed", "children": [
                {"nodeType": "Test Case", "nodeIdentifier": name + "/one()", "result": "Passed"}]}
                for name in required if name != missing]
            summary = dict(totalTestCount=len(nodes), passedTests=len(nodes), failedTests=0, skippedTests=0)
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, "required unit suite did not run"):
                verify_results(summary, {"testNodes": nodes}, [], required)

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

    def test_midi_rejects_a_missing_selected_suite_even_when_the_summary_is_green(self):
        calls = self.exercise("iphone", stage="midi")
        selected = calls[1][1][4:]
        built = [arg.removeprefix("-only-testing:") for arg in calls[0][1] if arg.startswith("-only-testing:")]
        self.assertEqual(built, selected)
        required = self.checked_bundles[0].args[1]
        cases = {}
        for selection in selected:
            cases[selection] = [{"nodeType": "Test Case", "nodeIdentifier": name + "()", "result": "Passed"}
                                for name in midi_suite_tests(selection)]

        def verify(selections):
            nodes = [case for selection in selections for case in cases[selection]]
            summary = dict(totalTestCount=len(nodes), passedTests=len(nodes), failedTests=0, skippedTests=0)
            verify_results(summary, {"testNodes": nodes}, required)

        verify(selected)
        for missing in selected:
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, "required test did not run"):
                verify([selection for selection in selected if selection != missing])

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

# Like ci/ui-tests.sh, whose EXIT cleanup (same-name-folder.sh remove) takes a moment to run.
STOP_SLOW_CLEANUP_SCRIPT = """
folder=$1
trap "sleep 1.5 && touch $folder/cleaned" EXIT
trap 'exit 130' INT TERM HUP
/bin/sh -c 'touch "$1/started"; exec sleep 60' tool $folder
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
    def test_a_second_stop_during_timestamp_capture_cannot_replace_the_first(self):
        for starting in [False, True]:
            for second in [signal.SIGHUP, signal.SIGTERM]:
                with self.subTest(starting=starting, second=second.name), tempfile.TemporaryDirectory(
                        dir=os.environ.get("UNIPAD_TEST_TMPDIR")) as folder:
                    run = ReleaseChecks(argparse.Namespace(
                        simulator="none", device="iphone", output=Path(folder) / "results",
                        derived_data=Path(folder) / "dd"))
                    run.starting = starting
                    run.child = None if starting else object()
                    interrupted = False

                    def clock():
                        nonlocal interrupted
                        if not interrupted:
                            interrupted = True
                            run.request_stop(second)
                        return 123.0

                    with patch("release_checks.time.monotonic", side_effect=clock) as read_clock, patch.object(
                            run, "signal_stage") as forward:
                        run.request_stop(signal.SIGTERM)
                    read_clock.assert_called_once_with()
                    self.assertEqual(run.stop_signal, signal.SIGTERM)
                    self.assertEqual(run.stop_requested, 123.0)
                    if starting:
                        self.assertEqual(run.pending_stop, signal.SIGTERM)
                        forward.assert_not_called()
                    else:
                        forward.assert_called_once_with(signal.SIGTERM)

    def interrupt(self, mode, grace, sig=signal.SIGINT):
        return self.interrupt_command(lambda folder: [sys.executable, "-c", STOP_CHILD.replace("{mode}", mode),
                                                      str(folder / "started")], grace, sig)

    def interrupt_command(self, command, grace, sig, inspect=None, then=()):
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
            for later in then:
                time.sleep(0.5)
                driver.send_signal(later)
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

    def test_a_second_stop_does_not_cut_off_the_stage_cleanup(self):
        for second in [signal.SIGHUP, signal.SIGTERM]:
            with self.subTest(second=second.name):
                seen = {}
                output, stage, seconds = self.interrupt_command(
                    lambda folder: ["/bin/zsh", "-c", STOP_SLOW_CLEANUP_SCRIPT, "stage", str(folder)],
                    grace=10, sig=signal.SIGTERM, then=[second],
                    inspect=lambda folder: seen.update(cleaned=(folder / "cleaned").exists()))
                self.assertIn(f"InterruptedError interrupted by signal {int(signal.SIGTERM)}", output)
                self.assertTrue(seen["cleaned"])
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
