import unittest
import hashlib
import json
import plistlib
from types import SimpleNamespace
from pathlib import Path
import tempfile
from unittest.mock import patch
from native_grammar_results import summarize
import native_grammar_results
import run_native_grammar
from run_native_grammar import tree_sha256


def case(name, result="Passed", children=None):
    return {"nodeType": "Test Case", "nodeIdentifier": name, "name": name,
            "result": result, "children": children or []}


class NativeGrammarResultsTests(unittest.TestCase):
    def test_raw_bundle_digest_sorts_relative_path_strings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            names = ["Data/x", "Data-1", "Data.plist"]
            for name in names:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
            expected = hashlib.sha256()
            for name in sorted(names):
                expected.update(name.encode() + b"\0")
                expected.update(hashlib.sha256(name.encode()).digest())
            self.assertEqual(tree_sha256(root), expected.hexdigest())

    def test_both_entry_points_write_the_same_report_without_devices(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "run"
            argv = ["run_native_grammar.py", "--udid", "sim", "--case-sensitive-root", str(root),
                    "--derived-data", str(root / "build"), "--out", str(output),
                    "--grammar-version", "G2", "--grammar-revision", "revision"]

            def fake_run(command, **kwargs):
                if "build-for-testing" in command:
                    products = root / "build/Build/Products"
                    products.mkdir(parents=True)
                    (products / "fixture.xctestrun").write_bytes(plistlib.dumps({
                        "TestConfigurations": [{"TestTargets": [{"EnvironmentVariables": {}}]}]}))
                elif "test-without-building" in command:
                    (output / "NativeGrammar.xcresult").mkdir()
                return SimpleNamespace(returncode=0, stdout=json.dumps({"testNodes": [case("Other/소리()")]}, ensure_ascii=False), stderr="")

            with patch("sys.argv", argv), patch.object(run_native_grammar, "capture", return_value="소리"), \
                    patch.object(run_native_grammar.subprocess, "check_output", return_value=b""), \
                    patch.object(run_native_grammar.subprocess, "run", side_effect=fake_run):
                self.assertEqual(run_native_grammar.main(), 0)
            standalone = root / "standalone.json"
            with patch("sys.argv", ["native_grammar_results.py", "--tests", str(output / "tests.json"),
                                    "--metadata", str(output / "metadata.json"), "--out", str(standalone)]):
                native_grammar_results.main()
            paths = [output / "ios-native.json", standalone]
            for path in paths:
                self.assertIn("소리", path.read_text())
            reports = [json.loads(path.read_text()) for path in paths]
            for report in reports:
                self.assertTrue(report.pop("generatedAt"))
                self.assertEqual(report["environment"], [])
                self.assertTrue(all(rule["status"] == "unverified" for rule in report["rules"].values()))
            self.assertEqual(*reports)

    def test_raw_bundle_digest_binds_names_and_contents_independently_of_creation_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first, second = root / "first", root / "second"
            first.mkdir(); second.mkdir()
            for name in ["a", "b"]:
                (first / name).write_text(name)
            for name in ["b", "a"]:
                (second / name).write_text(name)
            self.assertEqual(tree_sha256(first), tree_sha256(second))
            (second / "b").write_text("changed")
            self.assertNotEqual(tree_sha256(first), tree_sha256(second))
            (second / "b").write_text("b")
            (second / "b").rename(second / "c")
            self.assertNotEqual(tree_sha256(first), tree_sha256(second))

    def report(self, nodes, code=0, devices=None):
        return summarize({"testNodes": nodes, "devices": [{"deviceId": "sim", "osVersion": "27.0"}] if devices is None else devices},
                         {"F-06": {"tests": ["Suite/one()", "Suite/two()"]}}, code)

    def test_every_linked_test_is_required(self):
        self.assertEqual(self.report([case("Suite/one()")])["F-06"]["status"], "unverified")

    def test_skipped_and_expected_failure_are_not_passes(self):
        for result in ["Skipped", "Expected Failure", "unknown"]:
            self.assertEqual(self.report([case("Suite/one()"), case("Suite/two()", result)])["F-06"]["status"], "unverified")

    def test_failed_repetition_is_not_erased_by_a_pass(self):
        nodes = [case("Suite/one()", "Passed", [
            {"nodeType": "Repetition", "name": "1", "result": "Failed"},
            {"nodeType": "Repetition", "name": "2", "result": "Passed"}]), case("Suite/two()")]
        self.assertEqual(self.report(nodes)["F-06"]["status"], "failed")

    def test_nonzero_exit_and_unknown_environment_cannot_confirm(self):
        nodes = [case("Suite/one()"), case("Suite/two()")]
        self.assertEqual(self.report(nodes, code=65)["F-06"]["status"], "unverified")
        self.assertEqual(self.report(nodes, devices=[])["F-06"]["status"], "unverified")

    def test_unrelated_failure_does_not_mark_passing_linked_tests_failed(self):
        nodes = [case("Suite/one()"), case("Suite/two()"), case("Other/timedOut()", "Failed")]
        self.assertEqual(self.report(nodes, code=65)["F-06"]["status"], "unverified")

    def test_unselected_rules_remain_unverified_when_selected_tests_fail(self):
        self.assertEqual(self.report([case("Other/selected()", "Failed")], code=65)["F-06"]["status"], "unverified")

    def test_linked_failure_is_failed_even_if_other_linked_tests_are_missing(self):
        self.assertEqual(self.report([case("Suite/one()", "Failed")], code=65)["F-06"]["status"], "failed")

    def test_all_observed_tests_pass(self):
        self.assertEqual(self.report([case("Suite/one()"), case("Suite/two()")])["F-06"]["status"], "passed")

    def test_empty_mapping_never_confirms_an_unimplemented_format(self):
        for code in [0, 65]:
            result = summarize({"testNodes": [], "devices": [{"deviceId": "sim", "osVersion": "27.0"}]}, {"A-03": {"tests": []}}, code)
            self.assertEqual(result["A-03"]["status"], "unverified")
