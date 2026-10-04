#!/usr/bin/env python3
"""Run the focused simulator plan and save exact commands/results; return the harness device."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import plistlib
import shutil
import tarfile
import time
import uuid
import re
import io
import fcntl
import signal
from contextlib import contextmanager


BUNDLE = "kim.jisub.unipad"
BACKGROUND_TEST = "unipadUITests/ReleaseFeatureUITests/testPreparedPackOpensAndBackgroundReturnStaysResponsive"
TARGET_TEST = BACKGROUND_TEST
CREDENTIAL_CONFIGS = {"GoogleService-Info.plist", "google-services.json"}



@contextmanager
def stop_signals():
    # Paperclip can stop a run while it owns a modified simulator. Convert
    # termination into the same exception path that restores data in finally.
    previous = signal.getsignal(signal.SIGTERM)
    def stop(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raise KeyboardInterrupt("Termination requested; restore and return the device")
    signal.signal(signal.SIGTERM, stop)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)


@contextmanager
def run_lock():
    # A second command from this run must not reuse the first command's lease
    # while its original app/data restoration is still in progress.
    path = Path(os.environ["PAPERCLIP_RUN_SCRATCH_DIR"]) / "release-features-device.lock"
    with path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Another release feature command is still running or restoring its device") from error
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)

def tree_hashes(root):
    if not root.is_dir() or root.is_symlink():
        raise RuntimeError(f"Not a directory: {root}")
    result = {}
    for path in sorted(root.rglob("*")):
        name = str(path.relative_to(root))
        if path.is_symlink():
            result[name] = "symlink:" + os.readlink(path)
        elif path.is_file():
            result[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif path.is_dir():
            result[name + "/"] = "directory"
    return result


def copy_verified(source, destination):
    if source.resolve().is_relative_to(destination.resolve()) or destination.resolve().is_relative_to(source.resolve()):
        raise RuntimeError("Backup paths must not overlap")
    before = tree_hashes(source)
    shutil.copytree(source, destination, symlinks=True)
    if tree_hashes(destination) != before or tree_hashes(source) != before:
        raise RuntimeError("Backup copy differs; no device data may be replaced")
    return before


def restore_tree(backup, destination, expected=None):
    if backup.resolve().is_relative_to(destination.resolve()) or destination.resolve().is_relative_to(backup.resolve()):
        raise RuntimeError("Restore paths must not overlap")
    actual = tree_hashes(backup)  # Validate before any destructive operation.
    if expected is not None and actual != expected:
        raise RuntimeError("Backup changed; preserve current data for inspection")
    if not destination.is_dir() or destination.is_symlink():
        raise RuntimeError("Current container is not a directory")
    for path in destination.iterdir():
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    shutil.copytree(backup, destination, dirs_exist_ok=True, symlinks=True)
    if tree_hashes(destination) != actual:
        raise RuntimeError("Restored container differs from the verified backup")



def reset_target_data(data):
    # Preserve CoreSimulator's container identity metadata; deleting it makes
    # the next Xcode install allocate a different data container and lose the fixture.
    for path in data.iterdir():
        if path.name == ".com.apple.mobile_container_manager.metadata.plist":
            continue
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()


def app_pid(output):
    matches = re.findall(r"^(\d+)\s+\S+\s+UIKitApplication:kim\.jisub\.unipad\[", output, re.M)
    if len(matches) > 1:
        raise RuntimeError("More than one target process; refuse ambiguous continuity")
    return int(matches[0]) if matches else None


def require_same_process(before, after):
    if before is None or after is None or before != after:
        raise RuntimeError(f"Target process restarted or disappeared: {before} -> {after}")


def command(record, argv, cwd=None, log=None, check=True, timeout=1800):
    row = {"command": list(map(str, argv))}
    record.setdefault("commands", []).append(row)
    try:
        if log:
            with log.open("w") as output:
                result = subprocess.run(argv, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
        else:
            result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)
            row["stdout"] = result.stdout
            row["stderr"] = result.stderr
        row["exitCode"] = result.returncode
    except subprocess.TimeoutExpired:
        row["timedOutAfterSeconds"] = timeout
        raise
    if check and result.returncode:
        raise RuntimeError(f"Command failed: {result.returncode}; {argv}; log={log}")
    return result


def container(record, device, kind, check=True):
    result = command(record, ["xcrun", "simctl", "get_app_container", device, BUNDLE, kind], check=check, timeout=30)
    if result.returncode:
        return None
    path = Path(result.stdout.strip())
    if not result.stdout.strip() or not path.is_dir():
        raise RuntimeError("App container is empty or unavailable")
    return path


def snapshot(record, device, out):
    command(record, ["xcrun", "simctl", "terminate", device, BUNDLE], check=False, timeout=30)
    listed = command(record, ["xcrun", "simctl", "listapps", device], timeout=30)
    converted = subprocess.run(["plutil", "-convert", "json", "-o", "-", "-"], input=listed.stdout, text=True, capture_output=True, check=True)
    apps = json.loads(converted.stdout)
    record["originalAppPresent"] = BUNDLE in apps
    if BUNDLE not in apps:
        return None
    app = container(record, device, "app")
    data = container(record, device, "data")
    backup = out / "original"
    backup.mkdir()
    saved = {"app": copy_verified(app, backup / "unipad.app"),
             "data": copy_verified(data, backup / "data"), "root": backup}
    record["originalAppHashes"] = saved["app"]
    record["originalDataHashes"] = saved["data"]
    record["backupVerified"] = True
    return saved


def restore(record, device, saved):
    command(record, ["xcrun", "simctl", "terminate", device, BUNDLE], check=False, timeout=30)
    command(record, ["xcrun", "simctl", "terminate", device, BUNDLE + "UITests.xctrunner"], check=False, timeout=30)
    if saved is None:
        command(record, ["xcrun", "simctl", "uninstall", device, BUNDLE], timeout=30)
        record["restoredOriginallyAbsentApp"] = container(record, device, "app", check=False) is None
        if not record["restoredOriginallyAbsentApp"]:
            raise RuntimeError("Originally absent app is still installed")
        return
    if tree_hashes(saved["root"] / "unipad.app") != saved["app"]:
        raise RuntimeError("Original app backup changed")
    if tree_hashes(saved["root"] / "data") != saved["data"]:
        raise RuntimeError("Original data backup changed")
    command(record, ["xcrun", "simctl", "install", device, str(saved["root"] / "unipad.app")], timeout=60)
    restore_tree(saved["root"] / "data", container(record, device, "data"), saved["data"])
    record["restoredAppHashes"] = tree_hashes(container(record, device, "app"))
    record["restoredDataHashes"] = tree_hashes(container(record, device, "data"))
    record["appRestored"] = record["restoredAppHashes"] == saved["app"]
    record["dataRestored"] = record["restoredDataHashes"] == saved["data"]
    if not record["appRestored"] or not record["dataRestored"]:
        raise RuntimeError("App or full data restoration hash comparison failed")


def fake_firebase(source):
    # This public, deliberately invalid configuration is never a production secret.
    path = source / "unipad/GoogleService-Info.plist"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps({"API_KEY": "not-a-real-api-key", "GOOGLE_APP_ID": "1:000000000000:ios:0000000000000000",
                                    "GCM_SENDER_ID": "000000000000", "PROJECT_ID": "release-tests-invalid",
                                    "BUNDLE_ID": BUNDLE, "PLIST_VERSION": "1", "IS_ANALYTICS_ENABLED": False}))


def stage_source(repo, destination, ref=None):
    destination.mkdir()
    if ref:
        names = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", ref], cwd=repo, text=True).splitlines()
        names = [name for name in names if Path(name).name not in CREDENTIAL_CONFIGS]
        archive = subprocess.check_output(["git", "archive", ref, "--", *names], cwd=repo)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(destination, filter="data")
    else:
        names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=repo).decode().split("\0")
        for name in names:
            if not name or Path(name).name in CREDENTIAL_CONFIGS or not (repo / name).is_file():
                continue
            path = destination / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(repo / name, path)
    fake_firebase(destination)


def summarize(result, row, out, plan=None):
    summary = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], text=True))
    row["summary"] = summary
    (out / (result.stem + "-summary.json")).write_text(json.dumps(summary, indent=2) + "\n")
    if summary.get("passedTests", 0) == 0 or summary.get("failedTests", 0) or summary.get("skippedTests", 0):
        raise RuntimeError("A passing run must execute tests, with no failures or skips")
    tree = json.loads(subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result)], text=True))
    (out / (result.stem + "-tests.json")).write_text(json.dumps(tree, indent=2) + "\n")
    executed = {}
    def collect(nodes, bundle=None):
        for node in nodes:
            current = node["name"] if node.get("nodeType") in ["Unit test bundle", "UI test bundle"] else bundle
            if node.get("nodeType") == "Test Case":
                executed.setdefault(current, []).append(node["nodeIdentifier"])
            collect(node.get("children", []), current)
    collect(tree["testNodes"])
    row["executedTests"] = executed
    if plan:
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
    return summary


def xcode_args(source, build, device, configuration="Release", testing=True):
    result = ["-project", str(source / "unipad.xcodeproj"), "-scheme", "unipad", "-configuration", configuration,
              "-destination", f"platform=iOS Simulator,id={device}", "-derivedDataPath", str(build),
              "CODE_SIGNING_ALLOWED=NO"]
    if testing:
        result += ["-parallel-testing-enabled", "NO", "-enableCodeCoverage", "NO", "-collect-test-diagnostics", "never"]
    return result


def crashes(device):
    roots = [Path.home() / "Library/Logs/DiagnosticReports",
             Path.home() / f"Library/Developer/CoreSimulator/Devices/{device}/data/Library/Logs/CrashReporter"]
    result = {}
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or not path.name.lower().startswith("unipad") or path.suffix not in [".ips", ".crash"]:
                continue
            content = path.read_bytes()
            # Host reports include every simulator. Ignore another worker's
            # device, and ignore mere timestamp changes to old report files.
            if root == roots[0] and device.lower().encode() not in content.lower():
                continue
            result[str(path)] = hashlib.sha256(content).hexdigest()
    return result



def acknowledge(directory, point, response):
    # Publish only complete JSON. XCTest can otherwise see an existing, empty
    # file between open/truncate and write, especially across simulator processes.
    staged = directory / (point + ".ack.tmp")
    staged.write_text(json.dumps(response))
    staged.replace(directory / (point + ".ack"))

def run_target_ui(record, argv, device, out, fault):
    points = ["capture-target-home", "capture-before-input", "capture-before-settings",
              "before-settings", "in-settings", "after-return", "capture-after-return",
              "capture-after-input", "after-input"]
    continuity_points = [point for point in points if not point.startswith("capture-")]
    row = {"command": argv, "checkpoints": []}
    record["runs"].append(row)
    before_crashes = crashes(device)
    started = time.monotonic()
    with (out / "test.log").open("w") as log:
        process = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        try:
            handled = set()
            while process.poll() is None:
                for point in points:
                    if point in handled or not (out / (point + ".ready")).exists():
                        continue
                    handled.add(point)
                    if point.startswith("capture-"):
                        name = point.removeprefix("capture-")
                        command(row, ["xcrun", "simctl", "io", device, "screenshot", str(out / (name + ".png"))], timeout=30)
                        row.setdefault("screenshots", []).append(name)
                        acknowledge(out, point, {})
                        continue
                    output = command(row, ["xcrun", "simctl", "spawn", device, "launchctl", "list"], timeout=30).stdout
                    pid = app_pid(output)
                    checkpoint = {"name": point, "pid": pid}
                    row["checkpoints"].append(checkpoint)
                    response = {}
                    try:
                        if point in ["before-settings", "after-input"]:
                            installed = tree_hashes(container(row, device, "app"))
                            checkpoint["installedAppMatchesTarget"] = installed == record["targetAppHashes"]
                            if not checkpoint["installedAppMatchesTarget"]:
                                raise RuntimeError("Installed app differs from the ordinary target Release product")
                        if point == "before-settings":
                            if pid is None:
                                raise RuntimeError("No target process before switch")
                            row["initialPid"] = pid
                        else:
                            require_same_process(row.get("initialPid"), pid)
                        if point == "in-settings" and fault:
                            command(row, ["xcrun", "simctl", "terminate", device, BUNDLE], timeout=30)
                            row["faultInjected"] = True
                            response["restart"] = "true"
                    except RuntimeError as error:
                        checkpoint["error"] = str(error)
                        response["error"] = str(error)
                    acknowledge(out, point, response)
                if time.monotonic() - started > 360:
                    row["timedOutAfterSeconds"] = 360
                    raise RuntimeError("Target UI test timed out after 360 seconds")
                time.sleep(0.1)
            row["exitCode"] = process.returncode
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=30)
    time.sleep(2)
    row["newCrashReports"] = [path for path, state in crashes(device).items() if before_crashes.get(path) != state]
    if row["exitCode"] or row["newCrashReports"] or any(point.get("error") for point in row["checkpoints"]):
        raise RuntimeError(f"Target UI failed: {row['exitCode']}; checkpoints={row['checkpoints']}; crashes={row['newCrashReports']}")
    if [point["name"] for point in row["checkpoints"]] != continuity_points:
        raise RuntimeError("Target UI did not execute every continuity checkpoint")
    # The normal app exposes no voice count. Retained trace strokes are the
    # production evidence that the pad canvas accepted input on each side.
    from PIL import Image, ImageChops
    if row.get("screenshots") != [point.removeprefix("capture-") for point in points if point.startswith("capture-")]:
        raise RuntimeError("Target UI did not capture every required screen")
    geometry = json.loads((out / "geometry.json").read_text())
    region = tuple(geometry[key] for key in ["left", "top", "right", "bottom"])
    row["inputGeometry"] = geometry
    for left, right in [("before-input", "before-settings"), ("after-return", "after-input")]:
        with Image.open(out / (left + ".png")) as a, Image.open(out / (right + ".png")) as b:
            scale = a.width / geometry["width"]
            if abs(a.height / geometry["height"] - scale) > 0.01 or a.size != b.size:
                raise RuntimeError("Screenshot does not match the recorded landscape window")
            box = tuple(round(value * scale) for value in region)
            changed = ImageChops.difference(a.convert("RGB").crop(box), b.convert("RGB").crop(box)).getbbox()
        row.setdefault("inputImageDifferences", []).append({"before": left, "after": right, "changedBounds": changed})
        if changed is None:
            raise RuntimeError("Pad trace did not change after input")
    return row


def target_checks(args, record, repo, source, build, device, out):
    ref = subprocess.check_output(["git", "rev-parse", args.target_ref + "^{commit}"], cwd=repo, text=True).strip()
    record["targetCommit"] = ref
    target_source = out / "target-source"
    stage_source(repo, target_source, ref)
    record["targetSourceHashes"] = tree_hashes(target_source)
    record["targetSourceHashes"].pop("unipad/GoogleService-Info.plist", None)
    target_build = (build.parent / (build.name + "-target-" + ref[:12])) if args.derived_data else out / "target-build"
    command(record, ["xcodebuild", "build", *xcode_args(target_source, target_build, device, testing=False),
                     "UNIPAD_TEST_CONDITIONS=", "ENABLE_TESTABILITY=NO"], log=out / "target-build.log")
    target_app = target_build / "Build/Products/Release-iphonesimulator/unipad.app"
    record["targetAppHashes"] = tree_hashes(target_app)
    record["targetAppInfo"] = {key: plistlib.loads((target_app / "Info.plist").read_bytes()).get(key)
                               for key in ["CFBundleShortVersionString", "CFBundleVersion"]}
    command(record, ["xcodebuild", "build-for-testing", *xcode_args(source, build, device),
                     "UNIPAD_TEST_CONDITIONS=UNIPAD_RELEASE_TESTS", "ENABLE_TESTABILITY=YES"], log=out / "driver-build.log")
    xctestruns = [path for path in (build / "Build/Products").glob("*.xctestrun")
                 if path.name.startswith("unipad_AllTests_")]
    if len(xctestruns) != 1:
        raise RuntimeError("Expected one freshly built test configuration")
    tests = plistlib.loads(xctestruns[0].read_bytes())
    token = str(uuid.uuid4())
    for configuration in tests["TestConfigurations"]:
        for target in configuration["TestTargets"]:
            if target.get("BlueprintName") == "unipadUITests":
                target.setdefault("EnvironmentVariables", {})["UNIPAD_TARGET_FIXTURE_TOKEN"] = token
    fixture_run = build / "Build/Products/fixture.xctestrun"
    fixture_run.write_bytes(plistlib.dumps(tests))
    fixture_result = out / "fixture.xcresult"
    argv = ["xcodebuild", "test-without-building", "-xctestrun", str(fixture_run),
            "-destination", f"platform=iOS Simulator,id={device}", "-parallel-testing-enabled", "NO",
            "-enableCodeCoverage", "NO", "-collect-test-diagnostics", "never",
            "-only-testing:" + BACKGROUND_TEST, "-resultBundlePath", str(fixture_result)]
    command(record, argv, log=out / "fixture.log")
    summarize(fixture_result, record.setdefault("fixtureRun", {}), out)
    fixture = container(record, device, "data") / f"Documents/ReleaseTests/{token}/UniPack/Release"
    fixture_hashes = copy_verified(fixture, out / "repeat-fixture")
    record["fixtureHashes"] = fixture_hashes
    command(record, ["xcrun", "simctl", "terminate", device, BUNDLE], check=False, timeout=30)
    command(record, ["xcrun", "simctl", "install", device, str(target_app)], timeout=60)
    data = container(record, device, "data")
    # The full original data is backed up before either build/test can modify it.
    # Use an empty test library/settings/history for both target versions.
    reset_target_data(data)
    library = data / "Documents/UniPack/Release"
    library.parent.mkdir(parents=True)
    copy_verified(out / "repeat-fixture", library)
    # Runner paths are absolute because this xctestrun remains beside the build products.
    for configuration in tests["TestConfigurations"]:
        configuration["TestTargets"] = [target for target in configuration["TestTargets"] if target.get("BlueprintName") == "unipadUITests"]
        for target in configuration["TestTargets"]:
            target["UITargetAppPath"] = str(target_app)
            target["UITargetAppBundleIdentifier"] = BUNDLE
            target["DependentProductPaths"] = [str(target_app) if Path(path).name == "unipad.app" else path
                                               for path in target.get("DependentProductPaths", []) if "/unipad.app/" not in path]
            target.pop("OnlyTestIdentifiers", None)
            target.pop("SkipTestIdentifiers", None)
            target["EnvironmentVariables"].pop("UNIPAD_TARGET_FIXTURE_TOKEN", None)
    record["collectionBlocked"] = {"launchEnvironment": {"XCTestConfigurationFilePath": "release-target-local-only"},
                                   "firebaseConfig": "generated invalid placeholder", "testConditions": "", "signing": False}
    record["screenEvidence"] = "common player menu and retained Trace Log canvas; no playPadGrid identifier"
    record["audioProbe"] = command(record, ["system_profiler", "SPAudioDataType", "-json"], check=False, timeout=60).stdout
    record["audioLimitation"] = "Host audio inventory does not expose per-simulator-app active voices. Fixture is silent; real output is not asserted. Instrumented scenario asserts active repeat voice."
    lock = command(record, ["xcrun", "simctl", "io", device, "press", "lock"], check=False, timeout=30)
    record["lockProbe"] = {"exitCode": lock.returncode, "stdout": lock.stdout, "stderr": lock.stderr}
    record["axeAvailable"] = shutil.which("axe") is not None
    record["lockLimitation"] = "simctl has no lock hardware-button command. Physical lock/unlock and real audio recovery require a physical iPhone."
    for iteration in range(1, args.iterations + 1):
        run_out = out / f"target-run-{iteration}"
        run_out.mkdir()
        for configuration in tests["TestConfigurations"]:
            for target in configuration["TestTargets"]:
                target["EnvironmentVariables"]["UNIPAD_TARGET_EVIDENCE"] = str(run_out)
        target_run = build / "Build/Products/target.xctestrun"
        target_run.write_bytes(plistlib.dumps(tests))
        result = run_out / "result.xcresult"
        argv = ["xcodebuild", "test-without-building", "-xctestrun", str(target_run),
                "-destination", f"platform=iOS Simulator,id={device}", "-parallel-testing-enabled", "NO",
                "-enableCodeCoverage", "NO", "-collect-test-diagnostics", "never",
                "-only-testing:" + TARGET_TEST, "-resultBundlePath", str(result)]
        row = run_target_ui(record, argv, device, run_out, args.inject_restart)
        summarize(result, row, run_out)
        if tree_hashes(target_app) != record["targetAppHashes"]:
            raise RuntimeError("Target app bytes changed during execution")
        print(f"Target {ref[:7]} run {iteration}: process {row['initialPid']} retained; input and player verified", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--os", default="", help="Harness runtime name, e.g. 26.3")
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Release")
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--derived-data", type=Path)
    parser.add_argument("--target-ref", help="Build this exact commit as an ordinary Release app")
    parser.add_argument("--inject-restart", action="store_true", help="Negative control: terminate target while Settings is foreground")
    args = parser.parse_args()
    if args.iterations < 1 or (args.inject_restart and not args.target_ref):
        parser.error("iterations must be positive; restart injection requires --target-ref")
    if args.target_ref and args.configuration != "Release":
        parser.error("target comparisons require Release")
    repo = Path(__file__).resolve().parent.parent
    out = Path(os.environ["PAPERCLIP_RUN_SCRATCH_DIR"]) / ("release-features-" + str(uuid.uuid4()))
    out.mkdir()
    print(f"Evidence: {out}", flush=True)
    harness = Path(os.environ["HARNESS"]) / "devices.py"
    record = {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
              "diffSha256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=repo)).hexdigest(),
              "configuration": args.configuration, "runs": []}
    source = out / "source"
    stage_source(repo, source)
    record["sourceHashesExclude"] = sorted(CREDENTIAL_CONFIGS)
    record["sourceSha256"] = tree_hashes(source)
    record["sourceSha256"].pop("unipad/GoogleService-Info.plist", None)
    plan = json.loads((repo / "ReleaseFeatures.xctestplan").read_text())
    device = None
    device_requested = False
    saved = None
    snapshot_complete = False
    failure = None
    cleanup_errors = []
    with run_lock(), stop_signals():
        try:
            device_requested = True
            device = subprocess.check_output(["python3", str(harness), "up-ios", *([args.os] if args.os else [])], text=True).strip()
            record["device"] = device
            saved = snapshot(record, device, out)
            snapshot_complete = True
            build = args.derived_data.resolve() if args.derived_data else out / "build"
            if args.target_ref:
                target_checks(args, record, repo, source, build, device, out)
            else:
                for iteration in range(1, args.iterations + 1):
                    result = out / f"run-{iteration}.xcresult"
                    argv = ["xcodebuild", "test", *xcode_args(source, build, device, args.configuration),
                            "-testPlan", "ReleaseFeatures", "-resultBundlePath", str(result),
                            "UNIPAD_TEST_CONDITIONS=UNIPAD_RELEASE_TESTS", "ENABLE_TESTABILITY=YES"]
                    row = {"iteration": iteration, "command": argv}
                    record["runs"].append(row)
                    row["exitCode"] = command(record, argv, log=out / f"run-{iteration}.log").returncode
                    summary = summarize(result, row, out, plan)
                    print(f"Run {iteration}: {summary['passedTests']} passed; no failures or skips", flush=True)
        except BaseException as error:
            failure = error
            record["executionError"] = f"{type(error).__name__}: {error}"
        finally:
            if device is not None:
                if snapshot_complete:
                    try:
                        restore(record, device, saved)
                    except BaseException as error:
                        cleanup_errors.append(f"restoration: {error}")
            if device_requested:
                try:
                    record["deviceDownExitCode"] = command(record, ["python3", str(harness), "down"], timeout=60).returncode
                except BaseException as error:
                    cleanup_errors.append(f"device return: {error}")
            record["cleanupErrors"] = cleanup_errors
            record["success"] = failure is None and not cleanup_errors
            (out / "receipt.json").write_text(json.dumps(record, indent=2) + "\n")
    if failure or cleanup_errors:
        raise RuntimeError(f"Execution failed: {failure}; cleanup errors: {cleanup_errors}; evidence={out}") from failure
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
