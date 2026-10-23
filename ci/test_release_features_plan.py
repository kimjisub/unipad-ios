"""Keep the release basic-feature test plan pointing at checks that exist and run."""
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCHEME = ROOT / "unipad.xcodeproj/xcshareddata/xcschemes/unipad.xcscheme"


def swift_sources(target):
    return {path.stem: path.read_text() for path in (ROOT / target).rglob("*.swift")}


def declares(sources, kind, name):
    pattern = re.compile(rf"\b{kind}\s+{re.escape(name)}\b")
    return any(pattern.search(text) for text in sources.values())


class ReleaseFeaturesPlanTests(unittest.TestCase):
    def setUp(self):
        self.plan = json.loads((ROOT / "ReleaseFeatures.xctestplan").read_text())

    def test_scheme_offers_both_plans_and_runs_everything_by_default(self):
        scheme = SCHEME.read_text()
        self.assertIn('shouldAutocreateTestPlan = "NO"', scheme)
        default = re.search(r'reference = "container:(\w+)\.xctestplan"\s+default = "YES"', scheme)
        self.assertEqual(default and default.group(1), "AllTests")
        self.assertIn('reference = "container:ReleaseFeatures.xctestplan"', scheme)
        all_tests = json.loads((ROOT / "AllTests.xctestplan").read_text())
        targets = {entry["target"]["name"]: entry for entry in all_tests["testTargets"]}
        self.assertEqual(set(targets), {"unipadTests", "unipadUITests"})
        for entry in targets.values():
            self.assertNotIn("selectedTests", entry)
            self.assertNotIn("skippedTests", entry)

    def test_every_selected_check_exists(self):
        for entry in self.plan["testTargets"]:
            target = entry["target"]["name"]
            sources = swift_sources(target)
            selected = entry["selectedTests"]
            for suite in selected.get("suites", []):
                self.assertTrue(declares(sources, "struct", suite["name"]) or declares(sources, "class", suite["name"]),
                                f"{target}/{suite['name']} is not a test suite")
                self.assertTrue(any(f"{suite['name']} {{" in text and "import Testing" in text
                                    for text in sources.values()), f"{suite['name']} is not a Swift Testing suite")
            for test_class in selected.get("xctestClasses", []):
                name = test_class["name"]
                source = sources.get(name, "")
                self.assertRegex(source, rf"class\s+{name}\s*:\s*XCTestCase", f"{target}/{name} is not an XCTestCase")
                for method in test_class.get("xctestMethods", []):
                    self.assertIn(f"func {method.removesuffix('()')}(", source, f"{name}/{method} does not exist")

    def test_nothing_selected_is_left_out_by_the_ui_script(self):
        script = (ROOT / "ci/ui-tests.sh").read_text()
        left_out = re.findall(r"-skip-testing:unipadUITests/(\w+)(?:/(\w+))?", script)
        ui = next(entry for entry in self.plan["testTargets"] if entry["target"]["name"] == "unipadUITests")
        for test_class in ui["selectedTests"]["xctestClasses"]:
            methods = test_class.get("xctestMethods")
            for skipped_class, skipped_method in left_out:
                if skipped_class != test_class["name"]:
                    continue
                self.assertTrue(skipped_method and methods and f"{skipped_method}()" not in methods,
                                f"{test_class['name']} is selected but ci/ui-tests.sh leaves {skipped_method or 'it'} out")

    def test_plan_isolates_every_launch(self):
        variables = {item["key"]: item["value"] for item in self.plan["defaultOptions"]["environmentVariableEntries"]}
        self.assertEqual(variables.get("UNIPAD_RELEASE_SUITE"), "1")
        for entry in self.plan["testTargets"]:
            self.assertFalse(entry.get("parallelizable", True), "release checks share one simulator in order")


if __name__ == "__main__":
    unittest.main()
