"""Keep the isolated-library launch arguments in one place.

UITestSupport's launch-argument helpers write each of these keys once per launch. A test that
uses a helper and also appends one of these keys passes two values for the same key, and which
one the app reads is not specified. A test that builds its whole argument list itself (such as
the virtual MIDI round trip, whose library its own script prepares) does not mix the two.
"""
from pathlib import Path
import re
import unittest

KEYS = ("-UniPadReleaseTest", "-UniPadUITestLibrary", "-UniPadReleaseEmpty", "-UniPadReleaseFile",
        "-UniPadReleaseThemeLoading", "-UniPadReleaseArchive")
HELPERS = re.compile(r"UITestSupport\.(englishLaunchArguments|launchArguments|isolatedLibraryLaunchArguments)\(")


class UILaunchArgumentsTests(unittest.TestCase):
    def test_tests_using_the_shared_helper_do_not_write_its_keys_again(self):
        tests = Path(__file__).resolve().parents[1] / "unipadUITests"
        pattern = re.compile("|".join(re.escape(f'"{key}"') for key in KEYS))
        offenders = []
        for path in sorted(tests.rglob("*.swift")):
            if path.name == "UITestSupport.swift":
                continue
            lines = path.read_text().splitlines()
            if not any(HELPERS.search(line) for line in lines):
                continue
            offenders += [f"{path.name}:{number}" for number, line in enumerate(lines, 1) if pattern.search(line)]
        self.assertEqual(offenders, [], "pass these through the UITestSupport launch-argument helpers")


if __name__ == "__main__":
    unittest.main()
