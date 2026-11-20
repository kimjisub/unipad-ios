"""The side-by-side tool test runner fails exactly when running the files one by one would."""
import io
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import run_tool_tests

PASSING = '''
import unittest
class Passing(unittest.TestCase):
    def test_one(self): pass
    def test_two(self): pass
'''
FAILING = '''
import unittest
class Failing(unittest.TestCase):
    def test_wrong(self): self.assertEqual(1, 2)
'''
EMPTY = '''
import unittest
'''
SLOW = '''
import time, unittest
class Slow(unittest.TestCase):
    def test_waits(self): time.sleep(2)
'''
# Built in two parts so this file itself does not count as one that compiles Swift.
SWIFT = '''
import unittest
# compiles with ''' + 'swift' + '''c
class Swift(unittest.TestCase):
    def test_compiles(self): pass
'''


class RunToolTestsTests(unittest.TestCase):
    def run_folder(self, files: dict[str, str], workers: int = 4):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name, text in files.items():
                (folder / name).write_text(text)
            results, expected = run_tool_tests.run_all(folder, workers)
            with redirect_stdout(io.StringIO()) as output:
                code = run_tool_tests.report(results, expected)
        return code, results, expected, output.getvalue()

    def test_every_test_of_every_file_runs_and_is_counted(self):
        code, results, expected, output = self.run_folder(
            {'test_a.py': PASSING, 'test_b.py': PASSING, 'test_c.py': SLOW})
        self.assertEqual(code, 0, output)
        self.assertEqual(expected, 5)
        self.assertEqual(sum(result.tests for result in results), 5)
        self.assertIn('5 tests run in 3 files; unittest discovers 5', output)

    def test_one_failing_file_fails_the_run_and_keeps_its_output(self):
        code, _, _, output = self.run_folder({'test_a.py': PASSING, 'test_b.py': FAILING})
        self.assertEqual(code, 1)
        self.assertIn('FAILED: test_b.py failed', output)
        self.assertIn('AssertionError: 1 != 2', output)

    def test_a_file_that_runs_no_tests_fails_the_run(self):
        code, _, _, output = self.run_folder({'test_a.py': PASSING, 'test_b.py': EMPTY})
        self.assertEqual(code, 1)
        self.assertIn('FAILED: test_b.py ran no tests', output)

    def test_test_output_cannot_replace_the_test_count(self):
        noisy = '''
import unittest
class Noisy(unittest.TestCase):
    def test_prints_a_nested_summary(self):
        print("Ran 12 tests in 0.004s")
        self.assertTrue(True)
'''
        code, results, expected, output = self.run_folder({'test_probe.py': noisy})
        self.assertEqual(code, 0, output)
        self.assertEqual(expected, 1)
        self.assertEqual(results[0].tests, 1)
        self.assertIn('Ran 12 tests in 0.004s', output)

    def test_import_output_cannot_replace_the_discovered_count(self):
        code, results, expected, output = self.run_folder(
            {'test_probe.py': 'print("diagnostic from test import")\n' + PASSING})
        self.assertEqual(code, 0, output)
        self.assertEqual(expected, 2)
        self.assertEqual(results[0].tests, 2)
        self.assertIn('diagnostic from test import', output)

    def test_a_child_that_exits_without_a_result_fails_the_run(self):
        exits = '''
import os, unittest
class Exits(unittest.TestCase):
    def test_exits_early(self): os._exit(0)
'''
        code, results, _, output = self.run_folder({'test_probe.py': exits})
        self.assertEqual(code, 1, output)
        self.assertEqual(results[0].tests, 0)

    def test_a_missing_test_fails_even_when_the_file_succeeds(self):
        result = run_tool_tests.FileResult('test_probe.py', 0, 1, 0, '')
        with redirect_stdout(io.StringIO()) as output:
            code = run_tool_tests.report([result], expected=2)
        self.assertEqual(code, 1, output.getvalue())
        self.assertIn('1 tests ran but 2 were discovered', output.getvalue())

    def test_files_run_side_by_side(self):
        started = time.monotonic()
        code, _, _, output = self.run_folder({f'test_{n}.py': SLOW for n in 'abcd'}, workers=4)
        elapsed = time.monotonic() - started
        self.assertEqual(code, 0, output)
        self.assertLess(elapsed, 4 * 2, 'the four files ran one after another')

    def test_swift_compiling_files_start_first(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            for name, text in {'test_a.py': PASSING, 'test_z.py': SWIFT}.items():
                (folder / name).write_text(text)
            self.assertEqual([path.name for path in run_tool_tests.test_files(folder)],
                             ['test_z.py', 'test_a.py'])


class WorkflowTests(unittest.TestCase):
    def test_the_ios_check_runs_every_tool_test_through_the_runner(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-checks.yml').read_text()
        self.assertIn('python3 ci/run_tool_tests.py', workflow)
        self.assertNotIn('unittest discover', workflow)


if __name__ == '__main__':
    unittest.main()
