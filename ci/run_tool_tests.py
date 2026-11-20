#!/usr/bin/env python3
"""Run every ci/test_*.py file at once, each in its own unittest process, and report them together.

Most of the time these tests take is waiting: the picker probes replay UI-test waits in real
time and use almost no CPU. Run one after another they took about 160 s of the iOS check;
run side by side, the whole set takes about as long as its slowest file.

Each file uses the same discovery and imports as `python3 -m unittest discover -s ci -p FILE`.
Counts are written to separate result files, never parsed from diagnostic output. Files that
compile Swift start first because they are the slowest. The run fails when any file fails,
when a file runs no tests, or when the number of tests run differs from the number unittest
discovers in the folder.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

CI = Path(__file__).resolve().parent


@dataclass
class FileResult:
    name: str
    returncode: int
    tests: int
    seconds: float
    output: str


def test_files(folder: Path) -> list[Path]:
    files = sorted(folder.glob('test_*.py'))
    return sorted(files, key=lambda path: 'swiftc' not in path.read_text())


def discovered_count(folder: Path, python: str) -> int:
    # Discovered in a separate process: importing the test files here would leave them in
    # this process's module table under names another folder's files may reuse.
    script = '''
import sys, unittest
from pathlib import Path
suite = unittest.defaultTestLoader.discover(sys.argv[1])
Path(sys.argv[2]).write_text(str(suite.countTestCases()))
'''
    # Imports may print diagnostics too; neither count is parsed from normal output.
    with tempfile.TemporaryDirectory() as directory:
        count_path = Path(directory) / 'count'
        subprocess.run([python, '-c', script, str(folder), str(count_path)], check=True,
                       stdout=subprocess.PIPE, text=True)
        return int(count_path.read_text())


def run_file(path: Path, python: str) -> FileResult:
    started = time.monotonic()
    script = '''
import sys, unittest
from pathlib import Path
suite = unittest.defaultTestLoader.discover(sys.argv[1], pattern=sys.argv[2])
result = unittest.TextTestRunner(verbosity=2).run(suite)
Path(sys.argv[3]).write_text(str(result.testsRun))
sys.exit(0 if result.wasSuccessful() else 1)
'''
    with tempfile.TemporaryDirectory() as directory:
        count_path = Path(directory) / 'count'
        result = subprocess.run(
            [python, '-c', script, str(path.parent), path.name, str(count_path)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            tests = int(count_path.read_text())
        except (OSError, ValueError) as error:
            return FileResult(path.name, result.returncode or 1, 0,
                              time.monotonic() - started,
                              result.stdout + f'\nCould not read unittest test count: {error}\n')
        return FileResult(path.name, result.returncode, tests,
                          time.monotonic() - started, result.stdout)


def run_all(folder: Path, workers: int, python: str = sys.executable) -> tuple[list[FileResult], int]:
    files = test_files(folder)
    expected = discovered_count(folder, python)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(lambda path: run_file(path, python), files))
    return results, expected


def report(results: list[FileResult], expected: int) -> int:
    failures = []
    for result in results:
        print(f'===== {result.name} ({result.seconds:.1f} s, {result.tests} tests, exit {result.returncode})')
        print(result.output, end='' if result.output.endswith('\n') else '\n')
        if result.tests == 0:
            failures.append(f'{result.name} ran no tests')
        elif result.returncode != 0:
            failures.append(f'{result.name} failed')
    total = sum(result.tests for result in results)
    print('===== summary')
    for result in sorted(results, key=lambda result: -result.seconds):
        print(f'{result.seconds:6.1f} s  {result.tests:3d} tests  exit {result.returncode}  {result.name}')
    print(f'{total} tests run in {len(results)} files; unittest discovers {expected}')
    if total != expected:
        failures.append(f'{total} tests ran but {expected} were discovered')
    for failure in failures:
        print(f'FAILED: {failure}')
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--folder', type=Path, default=CI)
    parser.add_argument('--workers', type=int, default=8)
    args = parser.parse_args(argv)
    results, expected = run_all(args.folder, args.workers)
    return report(results, expected)


if __name__ == '__main__':
    sys.exit(main())
