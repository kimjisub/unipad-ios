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
import time

from native_grammar_results import write_report

ROOT = Path(__file__).resolve().parent.parent
# The scheme has more than one test plan; build-for-testing writes an xctestrun per plan built.
TEST_PLAN = "AllTests"


def capture(command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def tree_sha256(directory):
    """Bind every regular file's relative path and contents, in sorted path order."""
    digest = hashlib.sha256()
    for path in sorted((p for p in directory.rglob("*") if p.is_file()),
                       key=lambda p: p.relative_to(directory).as_posix()):
        digest.update(path.relative_to(directory).as_posix().encode() + b"\0")
        file_digest = hashlib.sha256()
        with path.open("rb") as stream:
            while block := stream.read(1024 * 1024):
                file_digest.update(block)
        digest.update(file_digest.digest())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--case-sensitive-root", type=Path, required=True)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--grammar-version", required=True)
    parser.add_argument("--grammar-revision", required=True)
    parser.add_argument("--purpose", choices=["verification", "baseline", "mutation"], default="verification")
    parser.add_argument("--mutation-description")
    parser.add_argument("--only-testing", action="append")
    args = parser.parse_args()
    if (args.purpose == "mutation") != bool(args.mutation_description):
        parser.error("mutation runs require --mutation-description; other runs must omit it")
    args.out = args.out.resolve()
    args.derived_data = args.derived_data.resolve()
    args.case_sensitive_root = args.case_sensitive_root.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    destination = f"platform=iOS Simulator,id={args.udid},arch=arm64"
    source_diff = subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT)
    metadata = {"grammarVersion": args.grammar_version, "grammarRevision": args.grammar_revision,
                "purpose": args.purpose, "mutationDescription": args.mutation_description,
                "commit": capture(["git", "rev-parse", "HEAD"]),
                "sourceStatus": capture(["git", "status", "--porcelain"]),
                "sourceDiffSha256": hashlib.sha256(source_diff).hexdigest(),
                "xcode": capture(["xcodebuild", "-version"]), "host": capture(["sw_vers"]),
                "caseSensitiveRoot": str(args.case_sensitive_root),
                "startedAt": datetime.now(timezone.utc).isoformat(), "commands": [],
                "rawResults": "NativeGrammar.xcresult", "testTree": "tests.json"}
    corpus = "unipadTests/UniPackConformance/corpus.json"
    metadata["sharedCorpus"] = {
        "path": corpus, "sha256": hashlib.sha256((ROOT / corpus).read_bytes()).hexdigest(),
        "nativeRuleApplicability": "not-used",
        "reason": "Native rules use ZIP bytes, filesystem reads and audio fixtures; A-01/A-02 remain in the shared report.",
    }
    inputs = [
        "ci/native_grammar_mapping.json", "unipadTests/TestZip.swift",
        "unipadTests/UniPackRootNameTests.swift", "unipadTests/UniPackArchiveNameTests.swift",
        "unipadTests/UniPackArchiveLayoutTests.swift", "unipadTests/SoundEngineDecodingTests.swift",
        "unipadTests/OggVorbisDecoderTests.swift",
        "unipadTests/Fixtures/AudioFormats/vorbis-tone.ogg",
        "unipadTests/Fixtures/AudioFormats/vorbis-overlong.ogg",
        "unipadTests/Fixtures/AudioFormats/vorbis-over-budget.ogg",
        "unipadTests/Fixtures/AudioFormats/vorbis-at-limit.ogg",
        "unipadTests/Fixtures/AudioFormats/vorbis-oversized-codebook.ogg",
        "unipadTests/Fixtures/AudioFormats/aac-tone.m4a",
        "unipadTests/Fixtures/AudioFormats/mp3-tone-named-wav.wav",
        "unipadUITests/ExternalImportFixtures/BesideReadme.zip", "unipadUITests/ExternalFileImportTests.swift",
    ]
    metadata["inputs"] = [{"path": name, "sha256": hashlib.sha256((ROOT / name).read_bytes()).hexdigest()} for name in inputs]
    (args.out / "source.patch").write_bytes(source_diff)

    def run(command, name):
        started = time.monotonic()
        with (args.out / (name + ".log")).open("w") as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        metadata["commands"].append({"argv": command, "exitCode": result.returncode,
                                     "durationSeconds": time.monotonic() - started})
        (args.out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        return result.returncode

    build = ["xcodebuild", "build-for-testing", "-quiet", "-project", "unipad.xcodeproj", "-scheme", "unipad",
             "-testPlan", TEST_PLAN, "-configuration", "Debug", "-destination", destination, "-derivedDataPath", str(args.derived_data),
             "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "UNIPAD_WARNINGS_AS_ERRORS=YES"]
    build_started = time.time()
    code = run(build, "build")
    tree = {"testNodes": [], "devices": []}
    if code == 0:
        products = args.derived_data / "Build/Products"
        candidates = [p for p in products.glob(f"*_{TEST_PLAN}_*.xctestrun")
                      if p.stat().st_mtime >= build_started]
        if len(candidates) != 1:
            raise RuntimeError(f"Expected exactly one built xctestrun: {candidates}")
        config = plistlib.loads(candidates[0].read_bytes())
        targets = [t for c in config.get("TestConfigurations", []) for t in c.get("TestTargets", [])]
        if not targets:
            raise RuntimeError("No test targets in xctestrun")
        for target in targets:
            target.setdefault("EnvironmentVariables", {})["UNIPACK_CASE_ROOT"] = str(args.case_sensitive_root)
            target["EnvironmentVariables"]["UNIPACK_CONFORMANCE_OUT"] = str(args.out / "shared-conformance")
        # __TESTROOT__ must remain the build products directory.
        configured = products / "native-grammar-configured.xctestrun"
        configured.write_bytes(plistlib.dumps(config))
        metadata["xctestrunSha256"] = hashlib.sha256(configured.read_bytes()).hexdigest()
        (args.out / "configured.xctestrun").write_bytes(configured.read_bytes())
        test = ["xcodebuild", "test-without-building", "-quiet", "-xctestrun", str(configured),
                "-destination", destination, "-parallel-testing-enabled", "NO",
                "-collect-test-diagnostics", "never",
                "-resultBundlePath", str(args.out / "NativeGrammar.xcresult")]
        selections = args.only_testing or ["unipadTests", "unipadUITests/ExternalFileImportTests/testPackFolderBesideAReadmeImports"]
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
            metadata["rawResultsSha256"] = tree_sha256(raw)
            metadata["rawResultsHashAlgorithm"] = "SHA-256 of sorted relative UTF-8 paths + NUL + binary SHA-256 of each file"
    metadata["exitCode"] = code
    (args.out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (args.out / "tests.json").write_text(json.dumps(tree, indent=2) + "\n")
    report = write_report(tree, metadata, args.out / "ios-native.json")
    print(json.dumps({key: value["status"] for key, value in report["rules"].items()}))
    return code


if __name__ == "__main__":
    sys.exit(main())
