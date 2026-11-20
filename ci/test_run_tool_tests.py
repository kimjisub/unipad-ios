"""The side-by-side tool test runner fails exactly when running the files one by one would."""
import io
import os
import selectors
import signal
import subprocess
import sys
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

            # The compiler limit leaves other worker slots available for Python-only tests.
            for path in folder.glob('test_*.py'):
                path.unlink()
            for n in range(4):
                (folder / f'test_swift_{n}.py').write_text(SLOW + '\n# ' + 'swift' + 'c\n')
            (folder / 'test_plain.py').write_text(PASSING)
            active = set()
            maximum = 0
            plain_started_while_compilers_ran = False

            def started(name):
                nonlocal maximum, plain_started_while_compilers_ran
                if name == 'test_plain.py':
                    plain_started_while_compilers_ran = len(active) == 2
                else:
                    active.add(name)
                    maximum = max(maximum, len(active))

            results, expected = run_tool_tests.run_all(folder, 4,
                on_start=started, on_result=lambda result: active.discard(result.name))
            self.assertEqual(maximum, 2)
            self.assertTrue(plain_started_while_compilers_ran)
            self.assertEqual(sum(result.tests for result in results), expected)
            self.assertTrue(all(result.returncode == 0 for result in results))


class WorkflowTests(unittest.TestCase):
    def test_the_ios_check_runs_every_tool_test_through_the_runner(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-checks.yml').read_text()
        self.assertIn('python3 ci/run_tool_tests.py', workflow)
        self.assertNotIn('unittest discover', workflow)


class LiveOutputTests(unittest.TestCase):
    runner = Path(__file__).with_name('run_tool_tests.py')

    def launch(self, folder):
        return subprocess.Popen([sys.executable, '-u', str(self.runner), '--folder', str(folder),
                                 '--workers', '2'], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, start_new_session=True)

    def stop(self, process, child_file=None):
        if child_file is not None and child_file.exists():
            try:
                os.kill(int(child_file.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)

    def test_finished_failure_is_visible_before_the_slow_file_finishes(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            release = folder / 'release'
            (folder / 'test_a_fail.py').write_text(
                'import unittest\nclass Fast(unittest.TestCase):\n'
                ' def test_failure(self): self.assertTrue(False, "FAST-FAILURE")\n')
            (folder / 'test_z_slow.py').write_text(
                'import unittest, time\nfrom pathlib import Path\n'
                'class Slow(unittest.TestCase):\n'
                ' def test_wait(self):\n'
                f'  while not Path({str(release)!r}).exists(): time.sleep(.01)\n')
            process = self.launch(folder)
            output = bytearray()
            visible = False
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        for key, _ in selector.select(.1):
                            chunk = os.read(key.fd, 65536)
                            if not chunk:
                                break
                            output.extend(chunk)
                        if b'===== test_a_fail.py' in output and b'FAST-FAILURE' in output:
                            visible = True
                            break
                        if process.poll() is not None:
                            break
                # This barrier, rather than an elapsed-time comparison, defines the ordering.
                self.assertFalse(release.exists())
            finally:
                release.touch()
                try:
                    tail, _ = process.communicate(timeout=5)
                    output.extend(tail)
                finally:
                    self.stop(process)
            self.assertEqual(process.returncode, 1, output.decode(errors='replace'))
            self.assertTrue(visible, 'finished failure was hidden until the slow file ended:\n' +
                            output.decode(errors='replace'))

    def test_cancellation_preserves_unfinished_file_and_partial_output(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            for during_import in (False, True):
                with self.subTest(signal=signum, during_import=during_import), tempfile.TemporaryDirectory() as directory:
                    folder = Path(directory)
                    started = folder / 'started'
                    body = ('print("HANGING-MARKER", flush=True)\n'
                            f'Path({str(started) + ".tmp"!r}).write_text(str(os.getpid()))\n'
                            f'Path({str(started) + ".tmp"!r}).replace(Path({str(started)!r}))\n'
                            'while True: time.sleep(.05)\n')
                    source = 'import os, time, unittest\nfrom pathlib import Path\n'
                    if during_import:
                        source += body
                    else:
                        source += 'class Hang(unittest.TestCase):\n def test_hangs(self):\n'
                        source += ''.join('  ' + line + '\n' for line in body.splitlines())
                    (folder / 'test_hang.py').write_text(source)
                    process = self.launch(folder)
                    output = b''
                    timed_out = False
                    try:
                        deadline = time.monotonic() + 10
                        while not started.exists() and time.monotonic() < deadline:
                            time.sleep(.01)
                        self.assertTrue(started.exists(), 'the owned test process never started')
                        os.kill(process.pid, signum)
                        try:
                            output, _ = process.communicate(timeout=5)
                        except subprocess.TimeoutExpired:
                            timed_out = True
                        if not timed_out:
                            with self.assertRaises(ProcessLookupError, msg='cancelled child was not reaped'):
                                os.kill(int(started.read_text()), 0)
                    finally:
                        self.stop(process, started)
                    self.assertFalse(timed_out, 'cancellation did not finish')
                    self.assertNotEqual(process.returncode, 0)
                    text = output.decode(errors='replace')
                    self.assertIn('unfinished', text)
                    self.assertIn('test_hang.py', text)
                    self.assertIn('HANGING-MARKER', text)


if __name__ == '__main__':
    unittest.main()
