#!/usr/bin/env python3
"""Run the focused simulator plan and save exact commands/results; return the harness device."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os", default="", help="Harness runtime name, e.g. 26.3")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Release")
    parser.add_argument("--iterations", type=int, default=3)
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("iterations must be positive")
    repo = Path(__file__).resolve().parent.parent
    out = Path(os.environ["PAPERCLIP_RUN_SCRATCH_DIR"]) / "release-features"
    out.mkdir()  # Never overwrite a prior run's evidence.
    harness = Path(os.environ["HARNESS"]) / "devices.py"
    record = {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
              "diffSha256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=repo)).hexdigest(),
              "configuration": args.configuration, "runs": []}
    files = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=repo)
    credential_configs = {"GoogleService-Info.plist", "google-services.json"}
    record["sourceHashesExclude"] = sorted(credential_configs)
    record["sourceSha256"] = {name: hashlib.sha256((repo / name).read_bytes()).hexdigest()
                              for name in files.decode().split("\0") if name and Path(name).name not in credential_configs and (repo / name).is_file()}
    plan = json.loads((repo / "ReleaseFeatures.xctestplan").read_text())
    device = None
    try:
        device = subprocess.check_output(["python3", str(harness), "up-ios", *([args.os] if args.os else [])], text=True).strip()
        record["device"] = device
        for iteration in range(1, args.iterations + 1):
            result = out / f"run-{iteration}.xcresult"
            command = ["xcodebuild", "test", "-project", "unipad.xcodeproj", "-scheme", "unipad",
                       "-testPlan", "ReleaseFeatures", "-configuration", args.configuration,
                       "-destination", f"platform=iOS Simulator,id={device}",
                       "-derivedDataPath", str(out / "build"), "-parallel-testing-enabled", "NO",
                       "-enableCodeCoverage", "NO", "-collect-test-diagnostics", "never",
                       "-resultBundlePath", str(result), "UNIPAD_TEST_CONDITIONS=UNIPAD_RELEASE_TESTS",
                       "ENABLE_TESTABILITY=YES", "CODE_SIGNING_ALLOWED=NO"]
            row = {"iteration": iteration, "command": command}
            record["runs"].append(row)
            with (out / f"run-{iteration}.log").open("w") as log:
                row["exitCode"] = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=1800).returncode
            if row["exitCode"]:
                raise RuntimeError(f"Run {iteration} failed: {row['exitCode']}; inspect its log")
            summary = json.loads(subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], text=True))
            (out / f"run-{iteration}-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
            row["summary"] = summary
            if summary.get("passedTests", 0) == 0 or summary.get("failedTests", 0) or summary.get("skippedTests", 0):
                raise RuntimeError("A passing run must execute tests, with no failures or skips")
            tree = json.loads(subprocess.check_output(
                ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result)], text=True))
            (out / f"run-{iteration}-tests.json").write_text(json.dumps(tree, indent=2) + "\n")
            executed = {}

            def collect(nodes, bundle=None):
                for node in nodes:
                    current = node["name"] if node.get("nodeType") in ["Unit test bundle", "UI test bundle"] else bundle
                    if node.get("nodeType") == "Test Case":
                        executed.setdefault(current, []).append(node["nodeIdentifier"])
                    collect(node.get("children", []), current)

            collect(tree["testNodes"])
            row["executedTests"] = executed
            missing = []
            for target in plan["testTargets"]:
                identifiers = executed.get(target["target"]["name"], [])
                selection = target["selectedTests"]
                for group in selection.get("suites", []) + selection.get("xctestClasses", []):
                    name = group["name"]
                    methods = group.get("xctestMethods")
                    expected = [name + "/" + method for method in methods] if methods else [name]
                    for selected in expected:
                        if not any(test == selected or test.startswith(selected + "/") for test in identifiers):
                            missing.append(target["target"]["name"] + "/" + selected)
            if missing:
                raise RuntimeError("Selected checks did not execute: " + ", ".join(missing))
            print(f"Run {iteration}: {summary['passedTests']} passed; no failures or skips", flush=True)
    finally:
        (out / "receipt.json").write_text(json.dumps(record, indent=2) + "\n")
        if device is not None:
            for bundle in ["kim.jisub.unipad", "kim.jisub.unipadUITests.xctrunner"]:
                subprocess.run(["xcrun", "simctl", "terminate", device, bundle],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["python3", str(harness), "down"], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
