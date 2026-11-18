#!/usr/bin/env python3
"""Run release feature checks on a caller-acquired iPhone or iPad simulator.

Run both device commands before release. The iPhone command includes virtual
Launchpad input, device selection, lights and unplug/replug; the iPad command
includes every release UI check, window controls and pointer input. Neither
command acquires a device or establishes physical USB or audible sound quality.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from check_ui_results import check_summary

ROOT = Path(__file__).resolve().parents[1]
# How long a stage may clean up (e.g. stop its MIDI tools) after a stop request.
STOP_GRACE_SECONDS = 45


def screen_part(value):
    try:
        index, count = map(int, value.split("/"))
        if not 1 <= index <= count:
            raise ValueError()
    except ValueError as error:
        raise argparse.ArgumentTypeError("screen part must be INDEX/COUNT with 1 <= INDEX <= COUNT") from error
    return index, count


def required_ui_tests(plan):
    targets = json.loads((ROOT / f"{plan}.xctestplan").read_text())["testTargets"]
    ui = next(entry for entry in targets if entry["target"]["name"] == "unipadUITests")
    required = []
    for entry in ui["selectedTests"]["xctestClasses"]:
        name = entry["name"]
        methods = entry.get("xctestMethods")
        if methods is None:
            source = (ROOT / "unipadUITests" / f"{name}.swift").read_text()
            methods = [method + "()" for method in re.findall(r"\bfunc\s+(test\w+)\s*\(", source)]
        if not methods:
            raise ValueError(f"{plan}: {name} has no tests")
        required.extend(f"{name}/{method}" for method in methods)
    return required


def required_unit_suites(plan):
    targets = json.loads((ROOT / f"{plan}.xctestplan").read_text())["testTargets"]
    unit = next((entry for entry in targets if entry["target"]["name"] == "unipadTests"), None)
    if unit is None:
        return []
    selected = unit["selectedTests"]
    return [entry["name"] for key in ["suites", "xctestClasses"] for entry in selected.get(key, [])]


def required_midi_tests():
    source = (ROOT / "unipadUITests/VirtualMidiPlayScreenUITests.swift").read_text()
    required = ["VirtualMidiPlayScreenUITests/" + method
                for method in re.findall(r"\bfunc\s+(test\w+)\s*\(", source)]
    for suite in ["MidiInputPathTests", "MidiDeviceSelectionTests"]:
        source = (ROOT / "unipadTests" / f"{suite}.swift").read_text()
        methods = re.findall(r"@Test(?:\([^\n]*\))?\s+func\s+(\w+)\s*\(", source)
        if not methods:
            raise ValueError(f"{suite} has no tests")
        required.extend(f"PlayUsageRecordTests/{suite}/{method}" for method in methods)
    return required


def verify_results(summary, tree, required, suites=()):
    check_summary(summary)
    observed = set()
    passed_suites = set()

    def has_passed_case(node):
        return any(child.get("nodeType") == "Test Case" and child.get("result") == "Passed"
                   or has_passed_case(child) for child in node.get("children", []))

    def walk(node):
        if node.get("nodeType") == "Test Case":
            if node.get("result") != "Passed":
                raise ValueError(f"unverified test: {node.get('nodeIdentifier')}: {node.get('result')}")
            observed.add(node.get("nodeIdentifier", "").split("(", 1)[0])
        if node.get("nodeType") in {"Arguments", "Repetition", "Test Case Run"} and node.get("result") != "Passed":
            raise ValueError(f"unverified test run: {node}")
        if node.get("nodeType") in {"Skip Message", "Expected Failure"}:
            raise ValueError(f"unverified test result: {node}")
        if node.get("nodeType") == "Test Suite" and has_passed_case(node):
            passed_suites.add(node.get("name"))
        for child in node.get("children", []):
            walk(child)

    for node in tree.get("testNodes", []):
        walk(node)
    for suite in suites:
        if suite not in passed_suites:
            raise ValueError(f"required unit suite did not run: {suite}")
    for identifier in required:
        normalized = identifier.split("(", 1)[0]
        if not any(name == normalized or name.endswith("/" + normalized) for name in observed):
            raise ValueError(f"required test did not run: {identifier}")


class ReleaseChecks:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        # Never replace evidence from an earlier attempt.
        self.output.mkdir(parents=True, exist_ok=False)
        self.derived = args.derived_data.resolve()
        self.report = {"device": args.device, "simulator": args.simulator, "stages": [],
                       "requested_stage": getattr(args, "stage", "all"),
                       "screen_group": getattr(args, "screen_group", "all"),
                       "screen_part": getattr(args, "screen_part", None),
                       "command": sys.argv, "commit": subprocess.check_output(
                           ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                       "result": "incomplete"}
        self.child = None
        self.starting = False
        self.pending_stop = None
        self.stop_signal = None
        self.stop_requested = None

    def request_stop(self, sig):
        """Signal handler. Only forwards the stop; waiting and cleanup stay in the main flow."""
        if self.stop_signal is None:
            self.stop_signal, self.stop_requested = sig, time.monotonic()
        if self.child is not None:
            self.signal_stage(sig)
        elif self.starting:
            # stage() forwards it as soon as it holds the new process.
            self.pending_stop = sig
        else:
            raise InterruptedError(f"interrupted by signal {sig}")

    def signal_stage(self, sig):
        """Signal the stage's whole process group.

        A stage script waits for its foreground command (e.g. xcodebuild) before running
        its own traps, so the command must get the stop too; the script then cleans up.
        """
        try:
            os.killpg(self.child.pid, sig)
        except (ProcessLookupError, PermissionError):
            # The group is gone, or only exited processes are left in it.
            pass

    def wait_for_child(self):
        while True:
            try:
                return self.child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                if self.stop_requested is not None and time.monotonic() - self.stop_requested > STOP_GRACE_SECONDS:
                    self.signal_stage(signal.SIGKILL)
                    return self.child.wait()

    def save(self):
        (self.output / "result.json").write_text(json.dumps(self.report, indent=2) + "\n")

    def stage(self, name, command, env=None):
        record = {"name": name, "command": command, "result": "incomplete"}
        self.report["stages"].append(record)
        self.save()
        started = time.monotonic()
        print(f"Release checks: {name}", flush=True)
        with (self.output / f"{name}.log").open("w") as log:
            self.starting = True
            try:
                self.child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                              process_group=0)
            finally:
                self.starting = False
            try:
                pending, self.pending_stop = self.pending_stop, None
                if pending is not None:
                    self.signal_stage(pending)
                code = self.wait_for_child()
            finally:
                if self.child.poll() is None:
                    self.signal_stage(signal.SIGTERM)
                    try:
                        self.child.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        self.signal_stage(signal.SIGKILL)
                        self.child.wait()
                # Nothing the stage started may outlive it.
                self.signal_stage(signal.SIGKILL)
                record.update(exit_code=self.child.returncode, seconds=time.monotonic() - started)
                self.child = None
                self.save()
        if self.stop_signal is not None:
            raise InterruptedError(f"interrupted by signal {self.stop_signal}")
        if code:
            raise subprocess.CalledProcessError(code, command)
        record["result"] = "passed"
        self.save()

    def check_bundle(self, bundle, required, suites=()):
        results = {}
        for kind in ["summary", "tests"]:
            text = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", kind,
                                            "--path", str(bundle), "--compact"], text=True)
            bundle.with_suffix(f".{kind}.json").write_text(text)
            results[kind] = json.loads(text)
        verify_results(results["summary"], results["tests"], required, suites)

    def plan_command(self, plan, selection):
        return ["ci/ui-tests.sh", self.args.simulator, "-testPlan", plan, *selection]

    def plan_env(self, name):
        return dict(os.environ, UNIPAD_UI_TEST_CONFIGURATION="Release", UNIPAD_UI_TEST_DEVICE=self.args.device,
                    UNIPAD_UI_TEST_OUTPUT=str(self.output / name), UNIPAD_UI_TEST_DERIVED_DATA=str(self.derived))

    def execute(self):
        plan = "IPadReleaseFeatures" if self.args.device == "ipad" else "ReleaseFeatures"
        stage = getattr(self.args, "stage", "all")
        group = getattr(self.args, "screen_group", "all")
        part = getattr(self.args, "screen_part", None)
        if stage in {"all", "screen"}:
            required = required_ui_tests(plan)
            selection = []
            if group != "all":
                shared = set(required_ui_tests("ReleaseFeatures"))
                required = [name for name in required if (name in shared) == (group == "shared")]
                if not required:
                    raise ValueError(f"empty screen group: {group}")
            if part:
                index, count = part
                if count > len(required):
                    raise ValueError("screen parts must not contain empty runs")
                required = required[index - 1::count]
            # A selection narrows the run to UI tests; the plan's unit suites then need --stage unit.
            suites = required_unit_suites(plan)
            if group != "all" or part:
                selection = ["-only-testing:unipadUITests/" + name.split("(", 1)[0] for name in required]
                suites = []
            self.stage("screen", self.plan_command(plan, selection), env=self.plan_env("screen"))
            self.check_bundle(self.output / "screen" / "UITests.xcresult", required, suites)
        if stage == "unit":
            suites = required_unit_suites(plan)
            if not suites:
                raise ValueError(f"{plan} has no unit suites")
            self.stage("unit", self.plan_command(plan, ["-only-testing:unipadTests"]), env=self.plan_env("unit"))
            self.check_bundle(self.output / "unit" / "UITests.xcresult", [], suites)
        if self.args.device == "ipad" or stage in {"screen", "unit"}:
            return
        # These suites need one shared live CoreMIDI client. Build the Debug fixture
        # host once, then run all three against the same virtual-device session.
        suites = ["unipadTests/PlayUsageRecordTests/MidiInputPathTests",
                  "unipadTests/PlayUsageRecordTests/MidiDeviceSelectionTests",
                  "unipadUITests/VirtualMidiPlayScreenUITests"]
        if stage in {"all", "midi"}:
            self.stage("midi-build", ["xcodebuild", "build-for-testing", "-project", "unipad.xcodeproj",
                                 "-scheme", "unipad", "-configuration", "Debug", "-testPlan", "AllTests",
                                 "-destination", f"platform=iOS Simulator,id={self.args.simulator},arch=arm64",
                                 "-derivedDataPath", str(self.derived), "-onlyUsePackageVersionsFromResolvedFile",
                                 "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "UNIPAD_WARNINGS_AS_ERRORS=YES",
                                 *["-only-testing:" + suite for suite in suites]])
            midi = self.output / "midi"
            self.stage("midi", ["ci/midi-input-tests.sh", self.args.simulator, str(self.derived), str(midi), *suites])
            self.check_bundle(midi / "MidiInput.xcresult", required_midi_tests())
        if stage in {"all", "roundtrip"}:
            self.stage("roundtrip", [sys.executable, "ci/virtual_launchpad_roundtrip.py", "--simulator", self.args.simulator,
                                 "--output", str(self.output / "roundtrip"), "--derived-data", str(self.derived)])
            for order in ["midi", "screen"]:
                self.check_bundle(self.output / "roundtrip" / order / "UI.xcresult",
                                  ["VirtualLaunchpadRoundTripUITests/testRoundTrip()"])


def install_stop_handlers(run):
    for stop in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
        signal.signal(stop, lambda sig, frame: run.request_stop(sig))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--device", choices=["iphone", "ipad"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--stage", choices=["all", "screen", "unit", "midi", "roundtrip"], default="all",
                        help="run every stage, or one stage with its own complete result checks; "
                             "screen parts leave the release plan's unit suites to the unit stage")
    parser.add_argument("--screen-group", choices=["all", "shared", "ipad"], default="all",
                        help="split iPad screens into shared release screens and iPad-only additions")
    parser.add_argument("--screen-part", type=screen_part,
                        help="run INDEX/COUNT of a screen stage; every part is required for complete coverage")
    args = parser.parse_args()
    if args.device == "ipad" and args.stage not in {"all", "screen"}:
        parser.error("iPad checks have only the screen stage")
    if args.screen_group != "all" and (args.device != "ipad" or args.stage not in {"all", "screen"}):
        parser.error("--screen-group is only available for iPad screen checks")
    if args.screen_part and args.stage != "screen":
        parser.error("--screen-part requires --stage screen")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True))
    device = next((d for group in devices["devices"].values() for d in group if d["udid"] == args.simulator), None)
    if not device or device.get("state") != "Booted" or args.device not in device["deviceTypeIdentifier"].lower():
        parser.error("--device must match the booted simulator acquired by the caller")
    # The layout tests use safe areas measured independently on these models.
    if args.device == "ipad" and device["name"] != "iPad Pro 13-inch (M5)":
        parser.error("the iPad release plan uses independently measured iPad Pro 13-inch (M5) layout references")
    run = ReleaseChecks(args)
    install_stop_handlers(run)
    code = 0
    try:
        run.execute()
        run.report["result"] = "passed"
    except Exception as error:
        interrupted = run.stop_signal is not None
        run.report.update(result="interrupted" if interrupted else "failed", error=str(error))
        code = 128 + run.stop_signal if interrupted else 1
    finally:
        run.save()
    print(json.dumps(run.report, indent=2))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
