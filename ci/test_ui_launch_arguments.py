"""Keep the isolated-library launch arguments in one place.

UITestSupport.launchArguments writes each of these keys once per launch. A test that
appends one of them again passes two values for the same key, and which one the app
reads is not specified.
"""
from pathlib import Path
import re
import unittest

KEYS = ("-UniPadReleaseTest", "-UniPadUITestLibrary", "-UniPadReleaseEmpty", "-UniPadReleaseFile",
        "-UniPadReleaseThemeLoading", "-UniPadReleaseArchive")


class UILaunchArgumentsTests(unittest.TestCase):
    def test_only_the_shared_helper_writes_isolated_library_keys(self):
        tests = Path(__file__).resolve().parents[1] / "unipadUITests"
        pattern = re.compile("|".join(re.escape(f'"{key}"') for key in KEYS))
        offenders = [f"{path.name}:{number}"
                     for path in sorted(tests.rglob("*.swift")) if path.name != "UITestSupport.swift"
                     for number, line in enumerate(path.read_text().splitlines(), 1) if pattern.search(line)]
        self.assertEqual(offenders, [], "use UITestSupport.launchArguments for these keys")


if __name__ == "__main__":
    unittest.main()
