import unittest
from native_grammar_results import summarize


def case(name, result="Passed", children=None):
    return {"nodeType": "Test Case", "nodeIdentifier": name, "name": name,
            "result": result, "children": children or []}


class NativeGrammarResultsTests(unittest.TestCase):
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
        self.assertEqual(self.report(nodes, code=65)["F-06"]["status"], "failed")
        self.assertEqual(self.report(nodes, devices=[])["F-06"]["status"], "unverified")

    def test_all_observed_tests_pass(self):
        self.assertEqual(self.report([case("Suite/one()"), case("Suite/two()")])["F-06"]["status"], "passed")

    def test_empty_mapping_never_confirms_an_unimplemented_format(self):
        result = summarize({"testNodes": [], "devices": [{"deviceId": "sim", "osVersion": "27.0"}]}, {"A-03": {"tests": []}}, 0)
        self.assertEqual(result["A-03"]["status"], "unverified")
