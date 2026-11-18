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


def verify_results(summary, tree, required):
    check_summary(summary)
    observed = set()

    def walk(node):
        if node.get("nodeType") == "Test Case":
            if node.get("result") != "Passed":
                raise ValueError(f"unverified test: {node.get('nodeIdentifier')}: {node.get('result')}")
            observed.add(node.get("nodeIdentifier", "").split("(", 1)[0])
        if node.get("nodeType") in {"Arguments", "Repetition", "Test Case Run"} and node.get("result") != "Passed":
            raise ValueError(f"unverified test run: {node}")
        if node.get("nodeType") in {"Skip Message", "Expected Failure"}:
            raise ValueError(f"unverified test result: {node}")
        for child in node.get("children", []):
            walk(child)

    for node in tree.get("testNodes", []):
        walk(node)
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
                       "command": sys.argv, "commit": subprocess.check_output(
                           ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                       "result": "incomplete"}
        self.child = None

    def save(self):
        (self.output / "result.json").write_text(json.dumps(self.report, indent=2) + "\n")

    def stage(self, name, command, env=None):
        record = {"name": name, "command": command, "result": "incomplete"}
        self.report["stages"].append(record)
        self.save()
        started = time.monotonic()
        print(f"Release checks: {name}", flush=True)
        with (self.output / f"{name}.log").open("w") as log:
            self.child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                code = self.child.wait()
            finally:
                if self.child.poll() is None:
                    self.child.terminate()
                    self.child.wait(timeout=30)
                record.update(exit_code=self.child.returncode, seconds=time.monotonic() - started)
                self.child = None
                self.save()
        if code:
            raise subprocess.CalledProcessError(code, command)
        record["result"] = "passed"
        self.save()

    def check_bundle(self, bundle, required):
        results = {}
        for kind in ["summary", "tests"]:
            text = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", kind,
                                            "--path", str(bundle), "--compact"], text=True)
            bundle.with_suffix(f".{kind}.json").write_text(text)
            results[kind] = json.loads(text)
        verify_results(results["summary"], results["tests"], required)

    def execute(self):
        plan = "IPadReleaseFeatures" if self.args.device == "ipad" else "ReleaseFeatures"
        stage = getattr(self.args, "stage", "all")
        group = getattr(self.args, "screen_group", "all")
        if stage in {"all", "screen"}:
            required = required_ui_tests(plan)
            selection = []
            if group != "all":
                shared = set(required_ui_tests("ReleaseFeatures"))
                required = [name for name in required if (name in shared) == (group == "shared")]
                if not required:
                    raise ValueError(f"empty screen group: {group}")
                selection = ["-only-testing:unipadUITests/" + name.split("(", 1)[0] for name in required]
            screen = self.output / "screen"
            env = dict(os.environ, UNIPAD_UI_TEST_CONFIGURATION="Release", UNIPAD_UI_TEST_DEVICE=self.args.device,
                       UNIPAD_UI_TEST_OUTPUT=str(screen), UNIPAD_UI_TEST_DERIVED_DATA=str(self.derived))
            self.stage("screen", ["ci/ui-tests.sh", self.args.simulator, "-testPlan", plan, *selection], env=env)
            self.check_bundle(screen / "UITests.xcresult", required)
        if self.args.device == "ipad" or stage == "screen":
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--device", choices=["iphone", "ipad"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--stage", choices=["all", "screen", "midi", "roundtrip"], default="all",
                        help="run every stage, or one stage with its own complete result checks")
    parser.add_argument("--screen-group", choices=["all", "shared", "ipad"], default="all",
                        help="split iPad screens into shared release screens and iPad-only additions")
    args = parser.parse_args()
    if args.device == "ipad" and args.stage not in {"all", "screen"}:
        parser.error("iPad checks have only the screen stage")
    if args.screen_group != "all" and (args.device != "ipad" or args.stage not in {"all", "screen"}):
        parser.error("--screen-group is only available for iPad screen checks")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"], text=True))
    device = next((d for group in devices["devices"].values() for d in group if d["udid"] == args.simulator), None)
    if not device or device.get("state") != "Booted" or args.device not in device["deviceTypeIdentifier"].lower():
        parser.error("--device must match the booted simulator acquired by the caller")
    # The layout tests use safe areas measured independently on these models.
    if args.device == "ipad" and device["name"] != "iPad Pro 13-inch (M5)":
        parser.error("the iPad release plan uses independently measured iPad Pro 13-inch (M5) layout references")
    run = ReleaseChecks(args)

    def interrupted(sig, frame):
        # Forward to the foreground script so it can stop its owned MIDI tools.
        if run.child and run.child.poll() is None:
            run.child.send_signal(sig)
            run.child.wait(timeout=45)
        raise InterruptedError(f"interrupted by signal {sig}")

    for stop in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
        signal.signal(stop, interrupted)
    code = 0
    try:
        run.execute()
        run.report["result"] = "passed"
    except (Exception, KeyboardInterrupt) as error:
        run.report.update(result="failed", error=str(error))
        code = 1
    finally:
        run.save()
    print(json.dumps(run.report, indent=2))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
