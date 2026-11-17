#!/usr/bin/env python3
"""Record actual XCUITest pad input through a managed, process-specific recorder.

Acquire a simulator before running this command and return it afterwards. All
children run in the foreground and are reaped on exit. Existing evidence is
preserved. Exit 0: output matches; 1: output mismatch; 2: environment unverified.
This checks digital output, not speakers, Bluetooth, quality or playing latency.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import time
import uuid

from audio_output import assess, select_process

ROOT = Path(__file__).resolve().parents[1]
SCENARIOS = [
    ("normal-a", [1], 0, ((440,), (880,))),
    ("normal-b", [2], 0, ((662,), (998,))),
    ("left", [3], 0, ((1110,), ())),
    ("right", [4], 0, ((), (1374,))),
    ("no-press", [], 0, ((), ())),
    ("unmapped", [8], 0, ((), ())),
    ("silent", [5], 0, ((), ())),
    ("loop-stop", [6], 1.2, ((440,), (880,))),
    ("mixed", [1, 2], 0, ((440, 662), (880, 998))),
]


def make_cases(repeats):
    return [{"name": f"{repetition + 1:02}-{kind}", "kind": kind, "columns": columns,
             "hold": hold, "expected": expected}
            for repetition in range(repeats) for kind, columns, hold, expected in SCENARIOS]


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def app_identity(bundle):
    bundle = Path(bundle).resolve()
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    executable = info.get("CFBundleExecutable")
    if (not isinstance(executable, str) or Path(executable).name != executable
            or not (bundle / executable).is_file()):
        raise ValueError("the installed app has no valid executable")
    files = {}
    for path in sorted(bundle.rglob("*")):
        relative = path.relative_to(bundle).as_posix()
        if path.is_symlink():
            if not path.resolve().is_relative_to(bundle):
                raise ValueError("an installed app symlink escapes its bundle")
            files[relative] = {"symlink": os.readlink(path)}
        elif path.is_file():
            files[relative] = {"sha256": digest(path)}
    manifest = {"version": 1, "files": files}
    canonical = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
    return manifest | {"sha256": hashlib.sha256(canonical).hexdigest()}


def stage_fixture(destination, blocked):
    source = ROOT / "test-fixtures/AudioOutput"
    shutil.copytree(source, destination)  # refuses to replace any earlier evidence
    if blocked:
        lines = (destination / "keySound").read_text().splitlines()
        (destination / "keySound").write_text("".join(
            " ".join([*line.split()[:3], "silence.wav", *line.split()[4:]]) + "\n" for line in lines))
    return {"reference_manifest": json.loads((source / "manifest.json").read_text()),
            "playback_blocked": blocked,
            "staged_sha256": {path.relative_to(destination).as_posix(): digest(path)
                              for path in sorted(destination.rglob("*")) if path.is_file()}}


def validate_lease(lease, device, generation):
    if lease.get("platform") != "ios" or lease.get("device") != device or lease.get("generation") != generation:
        raise ValueError("the exact simulator rental generation is required")


class Run:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.children = []
        self.commands = []
        self.results = []
        self.report = {"status": "environment_unverified", "device": args.simulator,
                       "generation": args.generation, "command": sys.argv,
                       "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                       "source_diff_sha256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT)).hexdigest(),
                       "recorder_sha256": digest(args.recorder_binary), "app_sha256": None,
                       "app_identity": None,
                       "cases": self.results, "commands": self.commands}

    def start(self, command, log, env=None):
        child = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=env)
        self.children.append(child)
        self.commands.append({"command": list(map(str, command)), "pid": child.pid,
                              "started_monotonic_ns": time.monotonic_ns()})
        return child

    def command(self, command, timeout=120):
        at = len(self.commands)
        with tempfile_log(self.output / f"command-{at:03}.log") as log:
            child = self.start(command, log)
            try:
                child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                raise RuntimeError(f"command {at} timed out after {timeout} s")
        self.commands[at].update(exit=child.returncode, ended_monotonic_ns=time.monotonic_ns())
        text = (self.output / f"command-{at:03}.log").read_text()
        if child.returncode:
            raise RuntimeError(f"command {at} exited {child.returncode}: {text[-1000:]}")
        return text

    def device(self, *args):
        return self.command([sys.executable, str(self.args.device_tools / "devices.py"), *args])

    def wait(self, file, child, seconds):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if file.exists():
                return json.loads(file.read_text()) if file.suffix == ".json" else None
            if child.poll() is not None:
                raise RuntimeError(f"child exited {child.returncode} before {file.name}")
            time.sleep(0.02)
        raise RuntimeError(f"timed out after {seconds} s waiting for {file.name}")

    def save(self):
        (self.output / "summary.json").write_text(json.dumps(self.report, indent=2) + "\n")

    def run(self):
        args = self.args
        lease = json.loads(self.device("lease", args.simulator))
        validate_lease(lease, args.simulator, args.generation)
        self.report["xcode"] = self.command(["xcodebuild", "-version"])
        self.report["macos"] = self.command(["sw_vers"])
        devices = json.loads(self.command(["xcrun", "simctl", "list", "devices", "-j"]))
        self.report["simulator"] = [{"runtime": runtime, **device}
                                    for runtime, entries in devices["devices"].items() for device in entries
                                    if device["udid"] == args.simulator]
        build = ["xcodebuild", "build", "-quiet", "-project", "unipad.xcodeproj", "-scheme", "unipad",
                 "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={args.simulator},arch=arm64",
                 "-derivedDataPath", str(args.derived_data), "-onlyUsePackageVersionsFromResolvedFile",
                 "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "UNIPAD_WARNINGS_AS_ERRORS=YES"]
        if not args.reuse_build:
            self.command(build, timeout=900)
        app = args.derived_data / "Build/Products/Debug-iphonesimulator/unipad.app"
        prefix = ["ui", args.simulator, "--generation", args.generation, "--"]
        self.device(*prefix, "install", str(app))
        self.device(*prefix, "open", "kim.jisub.unipad")
        token = str(uuid.uuid4())
        fixture = self.output / "fixture"
        self.report["fixture"] = stage_fixture(fixture, args.block_playback)
        self.device("files", args.simulator, "--generation", args.generation, "--", "app-copy",
                    "kim.jisub.unipad", str(fixture), f"Documents/ReleaseTests/{token}/UniPack/AudioOutput")
        cases = make_cases(args.repeats)
        (self.output / "cases.json").write_text(json.dumps(cases))
        for case in cases:
            (self.output / case["name"]).mkdir()
        env = os.environ | {"TEST_RUNNER_UNIPAD_AUDIO_OUTPUT_DIR": str(self.output),
                            "TEST_RUNNER_UNIPAD_AUDIO_OUTPUT_TOKEN": token}
        command = [sys.executable, str(args.device_tools / "ios_tests.py"), args.simulator,
                   str(self.output / "ui"), "test-without-building" if args.reuse_build else "test",
                   "-project", "unipad.xcodeproj", "-scheme", "unipad",
                   "-configuration", "Debug", "-derivedDataPath", str(args.derived_data),
                   "-only-testing:unipadUITests/AudioOutputUITests", "-onlyUsePackageVersionsFromResolvedFile",
                   "-resultBundlePath", str(self.output / "UI.xcresult"),
                   "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "UNIPAD_WARNINGS_AS_ERRORS=YES"]
        with tempfile_log(self.output / "ui.log") as ui_log:
            ui = self.start(command, ui_log, env)
            for case in cases:
                step = self.output / case["name"]
                self.wait(step / "request", ui, 900 if not self.results else 20)
                entries = json.loads(self.device("audio-processes", args.simulator))
                pid = select_process(entries)
                (step / "target.json").write_text(json.dumps([v for v in entries if v.get("in_this_simulator")]))
                # Preserve only this rental's sound processes in the general command log too.
                (self.output / f"command-{len(self.commands) - 1:03}.log").write_text(
                    json.dumps([v for v in entries if v.get("in_this_simulator")]))
                if self.report["app_sha256"] is None:
                    container = self.command(["xcrun", "simctl", "get_app_container", args.simulator,
                                              "kim.jisub.unipad", "app"]).strip()
                    identity = app_identity(Path(container))
                    self.report.update(app_sha256=identity["sha256"], app_identity=identity)
                self.record(case, step, pid, ui)
            ui.wait(timeout=120)
            self.report["ui_exit"] = ui.returncode
            if ui.returncode:
                raise RuntimeError(f"UI test exited {ui.returncode}")
        path_verified = any(r["verdict"]["status"] == "pass" and any(r["case"]["expected"])
                            for r in self.results)
        if args.verified_capture:
            previous = json.loads(args.verified_capture.read_text())
            keys = ["device", "app_sha256", "app_identity", "recorder_sha256",
                    "source_commit", "source_diff_sha256"]
            if previous.get("status") != "pass" or any(previous.get(k) != self.report.get(k) for k in keys):
                raise RuntimeError("positive recording-path receipt does not match this app, device and recorder")
            path_verified = True
        statuses = [r["verdict"]["status"] for r in self.results]
        status = ("environment_unverified" if not path_verified or "environment_unverified" in statuses
                  else "fail" if "fail" in statuses else "pass")
        self.report.update(status=status, recording_path_verified=path_verified)
        self.save()
        return {"pass": 0, "fail": 1, "environment_unverified": 2}[status]

    def record(self, case, step, pid, ui):
        args = self.args
        command = [sys.executable, str(args.device_tools / "devices.py"), "record", args.simulator,
                   str(step / "output.wav"), "4", "--pid", str(pid), "--ready", str(step / "ready.json")]
        # Discovery and app hashing precede the UI peer's recorder-ready deadline.
        (step / "target-ready").touch()
        with tempfile_log(step / "recorder.log") as log:
            recorder = self.start(command, log)
            ready = self.wait(step / "ready.json", recorder, 10)
            try:
                recorder.wait(timeout=12)
            except subprocess.TimeoutExpired:
                raise RuntimeError("recording did not finish within its bounded window")
        summary = None
        for line in (step / "recorder.log").read_text().splitlines():
            try:
                value = json.loads(line)
                if isinstance(value, dict) and value.get("pid") == pid:
                    summary = value
            except ValueError:
                pass
        if (recorder.returncode not in (0, 6) or not summary or not summary.get("complete")
                or summary.get("discontinuities") or summary.get("packet_log_overflow")):
            reason = f"recording incomplete or unavailable: exit {recorder.returncode}"
            self.results.append({"case": case, "capture": summary, "recorder_exit": recorder.returncode,
                                 "verdict": {"status": "environment_unverified", "reason": reason}})
            self.save()
            raise RuntimeError(reason)
        gesture = self.wait(step / "input.json", ui, 2)
        verdict = assess(step / "output.wav", ready, gesture, case["expected"],
                         mixed=case["kind"] == "mixed", stopped=case["kind"] == "loop-stop")
        if case["kind"] in ("normal-a", "normal-b") and verdict["status"] == "pass":
            wrong = ((662,), (998,)) if case["kind"] == "normal-a" else ((440,), (880,))
            verdict["wrong_reference_rejected"] = assess(step / "output.wav", ready, gesture, wrong)["status"] == "fail"
            if not verdict["wrong_reference_rejected"]:
                verdict.update(status="fail", reason="an unrelated reference was accepted")
        result = {"case": case, "capture": summary, "recorder_exit": recorder.returncode,
                  "input": gesture, "verdict": verdict}
        self.results.append(result)
        self.save()
        (step / "done.json").write_text(json.dumps(verdict))
        print(case["name"], verdict["status"], verdict["reason"], flush=True)
        if verdict["status"] == "environment_unverified":
            raise RuntimeError(verdict["reason"])

    def close(self):
        (self.output / "abort").touch()
        for child in reversed(self.children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=10)
        self.save()


def tempfile_log(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    return path.open("w")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", required=True)
    parser.add_argument("--generation", required=True)
    parser.add_argument("--device-tools", type=Path, required=True)
    parser.add_argument("--recorder-binary", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeats", type=int, choices=range(1, 6), default=3)
    parser.add_argument("--block-playback", action="store_true")
    parser.add_argument("--verified-capture", type=Path)
    parser.add_argument("--reuse-build", action="store_true",
                        help="reuse the positive trial's app and test build without relinking")
    args = parser.parse_args()
    if args.reuse_build and not args.verified_capture:
        parser.error("--reuse-build requires --verified-capture")
    args.derived_data = args.derived_data.resolve()
    args.device_tools = args.device_tools.resolve()
    runner = Run(args)
    def stop(*_):
        raise RuntimeError("check interrupted")
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop)
    try:
        return runner.run()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        runner.report.update(status="environment_unverified", error=str(error))
        print(error, file=sys.stderr)
        return 2
    finally:
        runner.close()


if __name__ == "__main__":
    raise SystemExit(main())
