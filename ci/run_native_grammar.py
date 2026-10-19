"""Build and run native grammar checks on a simulator already lent to the caller.

No device lifecycle or disk creation here: the caller owns both. Use a fresh output
subdirectory for each attempt, preserving raw results before any rerun.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

from native_grammar_results import summarize

ROOT = Path(__file__).resolve().parent.parent


def capture(command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--case-sensitive-root", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--grammar-version", required=True)
    parser.add_argument("--grammar-revision", required=True)
    parser.add_argument("--only-testing", action="append")
    args = parser.parse_args()
    args.out = args.out.resolve()
    args.derived_data = args.derived_data.resolve()
    args.case_sensitive_root = args.case_sensitive_root.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    destination = f"platform=iOS Simulator,id={args.udid},arch=arm64"
    metadata = {"grammarVersion": args.grammar_version, "grammarRevision": args.grammar_revision,
                "commit": capture(["git", "rev-parse", "HEAD"]),
                "sourceStatus": capture(["git", "status", "--porcelain"]),
                "sourceDiffSha256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT)).hexdigest(),
                "xcode": capture(["xcodebuild", "-version"]), "host": capture(["sw_vers"]),
                "caseSensitiveRoot": str(args.case_sensitive_root),
                "startedAt": datetime.now(timezone.utc).isoformat(), "commands": [],
                "rawResults": "NativeGrammar.xcresult", "testTree": "tests.json"}
    (args.out / "source.patch").write_bytes(subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT))

    def run(command, name):
        with (args.out / (name + ".log")).open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        metadata["commands"].append({"argv": command, "exitCode": result.returncode})
        (args.out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        return result.returncode

    build = ["xcodebuild", "build-for-testing", "-quiet", "-project", "unipad.xcodeproj", "-scheme", "unipad",
             "-configuration", "Debug", "-destination", destination, "-derivedDataPath", str(args.derived_data),
             "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "UNIPAD_WARNINGS_AS_ERRORS=YES"]
    code = run(build, "build")
    tree = {"testNodes": [], "devices": []}
    if code == 0:
        products = args.derived_data / "Build/Products"
        candidates = [p for p in products.glob("*.xctestrun") if not p.name.startswith("native-grammar-")]
        if len(candidates) != 1:
            raise RuntimeError(f"Expected exactly one built xctestrun: {candidates}")
        config = plistlib.loads(candidates[0].read_bytes())
        targets = [t for c in config.get("TestConfigurations", []) for t in c.get("TestTargets", [])]
        if not targets:
            raise RuntimeError("No test targets in xctestrun")
        for target in targets:
            target.setdefault("EnvironmentVariables", {})["UNIPACK_CASE_ROOT"] = str(args.case_sensitive_root)
        # __TESTROOT__ must remain the build products directory.
        configured = products / "native-grammar-configured.xctestrun"
        configured.write_bytes(plistlib.dumps(config))
        metadata["xctestrunSha256"] = hashlib.sha256(configured.read_bytes()).hexdigest()
        (args.out / "configured.xctestrun").write_bytes(configured.read_bytes())
        test = ["xcodebuild", "test-without-building", "-quiet", "-xctestrun", str(configured),
                "-destination", destination, "-parallel-testing-enabled", "NO", "-retry-tests-on-failure", "NO",
                "-resultBundlePath", str(args.out / "NativeGrammar.xcresult")]
        selections = args.only_testing or ["unipadTests", "unipadUITests/ExternalFileImportTests"]
        test.extend("-only-testing:" + selection for selection in selections)
        code = run(test, "test")
        raw = args.out / "NativeGrammar.xcresult"
        if raw.exists():
            command = ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(raw)]
            exported = subprocess.run(command, capture_output=True, text=True)
            metadata["commands"].append({"argv": command, "exitCode": exported.returncode})
            (args.out / "export.log").write_text(exported.stderr)
            if exported.returncode == 0:
                tree = json.loads(exported.stdout)
    metadata["exitCode"] = code
    (args.out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (args.out / "tests.json").write_text(json.dumps(tree, indent=2) + "\n")
    mapping = json.loads(Path(__file__).with_name("native_grammar_mapping.json").read_text())
    report = {"schemaVersion": 1, "platform": "ios", "source": "native-tests", **metadata,
              "environment": tree["devices"], "rules": summarize(tree, mapping, code)}
    (args.out / "ios-native.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value["status"] for key, value in report["rules"].items()}))
    return code


if __name__ == "__main__":
    sys.exit(main())
