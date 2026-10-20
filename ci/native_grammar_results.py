"""Conservatively map native xcresult tests to grammar rules; never infer success from logs."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path


def summarize(tree, mapping, exit_code):
    observed = {}

    def walk(node):
        if node.get("nodeType") == "Test Case":
            identifier = node.get("nodeIdentifier", "")
            # Xcode may prefix a bundle name, but never match a method by substring.
            identifier = "/".join(identifier.split("/")[-2:])
            observed.setdefault(identifier, []).append(node)
        for child in node.get("children", []):
            walk(child)

    for node in tree.get("testNodes", []):
        walk(node)

    def outcomes(node):
        values = [node.get("result", "unknown")]
        for child in node.get("children", []):
            if child.get("nodeType") in {"Expected Failure", "Skip Message"}:
                values.append("unverified")
            if child.get("nodeType") in {"Arguments", "Repetition", "Test Case Run", "Device", "Test Plan Configuration"}:
                values.extend(outcomes(child))
        return values

    environment_known = bool(tree.get("devices")) and all(
        d.get("deviceId") and d.get("osVersion") for d in tree["devices"])
    result = {}
    for rule, entry in mapping.items():
        tests = [{"name": name, "runs": observed.get(name, [])} for name in entry["tests"]]
        values = [value for test in tests for run in test["runs"] for value in outcomes(run)]
        complete = bool(tests) and all(t["runs"] for t in tests)
        if not tests:
            status = "unverified"
        elif "Failed" in values:
            status = "failed"
        elif exit_code != 0 or not complete or not environment_known or any(v != "Passed" for v in values):
            status = "unverified"
        else:
            status = "passed"
        result[rule] = {"status": status, "tests": tests, "expectation": entry.get("expectation"),
                        "reason": entry.get("reason") if not complete else None}
    return result


def write_report(tree, metadata, out):
    """Write the same versioned report for live runs and saved-result exports."""
    mapping = json.loads(Path(__file__).with_name("native_grammar_mapping.json").read_text())
    report = {**metadata, "schemaVersion": 1, "platform": "ios", "source": "native-tests",
              "generatedAt": datetime.now(timezone.utc).isoformat(),
              "environment": tree.get("devices", []),
              "rules": summarize(tree, mapping, metadata["exitCode"])}
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    tree = json.loads(args.tests.read_text())
    metadata = json.loads(args.metadata.read_text())
    write_report(tree, metadata, args.out)


if __name__ == "__main__":
    main()
