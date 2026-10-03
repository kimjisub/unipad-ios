"""UI checks must run real tests without failures or missing-fixture skips."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class UIResultsTests(unittest.TestCase):
    def run_summary(self, summary):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'summary.json'
            path.write_text(json.dumps(summary))
            return subprocess.run(
                [sys.executable, str(Path(__file__).with_name('check_ui_results.py')), str(path)],
                capture_output=True, text=True,
            )

    def summary(self):
        return dict(totalTestCount=58, passedTests=58, failedTests=0, skippedTests=0)

    def test_accepts_all_tests_passing(self):
        result = self.run_summary(self.summary())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_fixture_skip_even_when_xcode_succeeds(self):
        summary = self.summary()
        summary.update(passedTests=57, skippedTests=1)
        self.assertNotEqual(self.run_summary(summary).returncode, 0)

    def test_rejects_failed_tests(self):
        summary = self.summary()
        summary.update(passedTests=57, failedTests=1)
        self.assertNotEqual(self.run_summary(summary).returncode, 0)

    def test_rejects_no_tests(self):
        summary = self.summary()
        summary.update(totalTestCount=0, passedTests=0)
        self.assertNotEqual(self.run_summary(summary).returncode, 0)

    def test_rejects_incomplete_results(self):
        summary = self.summary()
        del summary['skippedTests']
        self.assertNotEqual(self.run_summary(summary).returncode, 0)

    def test_rejects_unaccounted_tests(self):
        summary = self.summary()
        summary['passedTests'] = 57
        self.assertNotEqual(self.run_summary(summary).returncode, 0)

    def test_rejects_invalid_count_types(self):
        for value in ['58', True, -1, 58.0]:
            with self.subTest(value=value):
                summary = self.summary()
                summary['totalTestCount'] = value
                self.assertNotEqual(self.run_summary(summary).returncode, 0)


if __name__ == '__main__':
    unittest.main()
