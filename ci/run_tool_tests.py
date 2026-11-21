#!/usr/bin/env python3
"""Run all ci/test_*.py files, preserving counts, live progress and cancellation output.

Each file uses unittest discovery in its own process. Counts travel in separate files,
so diagnostic output cannot change them. At most two files that compile Swift run
at once; other files may fill the remaining worker slots. Every started process group is owned until it
finishes or cancellation terminates it. Final counts must match complete discovery.
"""
from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

CI = Path(__file__).resolve().parent
DISCOVER = '''
import sys, unittest
from pathlib import Path
suite = unittest.defaultTestLoader.discover(sys.argv[1])
Path(sys.argv[2]).write_text(str(suite.countTestCases()))
'''
RUN_FILE = '''
import sys, unittest
from pathlib import Path
suite = unittest.defaultTestLoader.discover(sys.argv[1], pattern=sys.argv[2])
result = unittest.TextTestRunner(verbosity=2).run(suite)
Path(sys.argv[3]).write_text(str(result.testsRun))
sys.exit(0 if result.wasSuccessful() else 1)
'''


@dataclass
class FileResult:
    name: str
    returncode: int
    tests: int
    seconds: float
    output: str


@dataclass
class Child:
    name: str
    process: subprocess.Popen
    started: float
    log: Path
    count: Path
    swift: bool = False


class DiscoveryCancelled(Exception):
    pass


def test_files(folder: Path) -> list[Path]:
    return sorted(sorted(folder.glob('test_*.py')),
                  key=lambda path: 'swiftc' not in path.read_text())


def start_child(name: str, folder: Path, python: str, script: str,
                args: list[str], swift: bool = False) -> Child:
    folder.mkdir()
    log, count = folder / 'output.log', folder / 'count'
    started = time.monotonic()
    with log.open('w') as output:
        process = subprocess.Popen([python, '-u', '-c', script, *args, str(count)],
                                   stdout=output, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
    return Child(name, process, started, log, count, swift)


def terminate(children: list[Child]) -> None:
    # Groups belong to the processes started above; include their compiler/probe children.
    for child in children:
        try:
            os.killpg(child.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 2
    while any(child.process.poll() is None for child in children) and time.monotonic() < deadline:
        time.sleep(.02)
    for child in children:
        try:
            os.killpg(child.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.process.wait()


def finish(child: Child) -> FileResult:
    code = child.process.wait()
    output = child.log.read_text(errors='replace')
    try:
        count = int(child.count.read_text())
    except (OSError, ValueError) as error:
        count, code = 0, code or 1
        output += f'\nCould not read unittest test count: {error}\n'
    return FileResult(child.name, code, count, time.monotonic() - child.started, output)


def discovered_count(folder: Path, python: str,
                     cancelled: Callable[[], bool] = lambda: False) -> int:
    with tempfile.TemporaryDirectory() as directory:
        child = start_child('discovery', Path(directory) / 'discovery', python,
                            DISCOVER, [str(folder)])
        try:
            while child.process.poll() is None:
                if cancelled():
                    terminate([child])
                    raise DiscoveryCancelled(child.log.read_text(errors='replace'))
                time.sleep(.02)
            if child.process.returncode:
                raise RuntimeError(child.log.read_text(errors='replace'))
            return int(child.count.read_text())
        finally:
            if child.process.poll() is None:
                terminate([child])


def run_file(path: Path, python: str) -> FileResult:
    with tempfile.TemporaryDirectory() as directory:
        child = start_child(path.name, Path(directory) / path.name, python,
                            RUN_FILE, [str(path.parent), path.name])
        try:
            child.process.wait()
            return finish(child)
        finally:
            if child.process.poll() is None:
                terminate([child])


def run_all(folder: Path, workers: int, python: str = sys.executable, *,
            on_start=None, on_result=None, on_cancel=None,
            cancelled: Callable[[], bool] = lambda: False,
            swift_workers: int = 2) -> tuple[list[FileResult], int]:
    if workers < 1 or (swift_workers is not None and swift_workers < 1):
        raise ValueError('worker counts must be positive')
    pending = test_files(folder)
    expected = discovered_count(folder, python, cancelled)
    results: list[FileResult] = []
    active: list[Child] = []
    with tempfile.TemporaryDirectory() as directory:
        try:
            while pending or active:
                if cancelled():
                    if on_cancel:
                        on_cancel([child.name for child in active] + [p.name for p in pending])
                    terminate(active)
                    for child in active:
                        result = finish(child)
                        results.append(result)
                        if on_result:
                            on_result(result)
                    for path in pending:
                        result = FileResult(path.name, 1, 0, 0, 'Not started: cancelled\n')
                        results.append(result)
                        if on_result:
                            on_result(result)
                    active.clear()
                    break
                while len(active) < workers:
                    swift_active = sum(child.swift for child in active)
                    eligible = next((p for p in pending if swift_workers is None or
                                     'swiftc' not in p.read_text() or swift_active < swift_workers), None)
                    if eligible is None:
                        break
                    pending.remove(eligible)
                    if on_start:
                        on_start(eligible.name)
                    child = start_child(eligible.name, Path(directory) / eligible.name, python,
                                        RUN_FILE, [str(eligible.parent), eligible.name],
                                        'swiftc' in eligible.read_text())
                    active.append(child)
                for child in active[:]:
                    if child.process.poll() is not None:
                        result = finish(child)
                        results.append(result)
                        active.remove(child)
                        if on_result:
                            on_result(result)
                if active:
                    time.sleep(.02)
        finally:
            if active:
                terminate(active)
    return results, expected


def print_result(result: FileResult) -> None:
    print(f'===== {result.name} ({result.seconds:.1f} s, {result.tests} tests, exit {result.returncode})', flush=True)
    print(result.output, end='' if result.output.endswith('\n') else '\n', flush=True)


def report(results: list[FileResult], expected: int, *, show_output: bool = True) -> int:
    failures = []
    for result in results:
        if show_output:
            print_result(result)
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
    if args.workers < 1:
        parser.error('worker counts must be positive')
    received = []
    def handle(signum, _frame):
        received.append(signum)
    def cancelled():
        return bool(received)
    def announce_cancel(names):
        print(f'CANCELLED {signal.Signals(received[0]).name}; unfinished: {", ".join(names)}', flush=True)
    old = {signum: signal.signal(signum, handle) for signum in (signal.SIGINT, signal.SIGTERM)}
    try:
        print('Discovering test counts', flush=True)
        try:
            results, expected = run_all(args.folder, args.workers,
                on_start=lambda name: print(f'START {name}', flush=True),
                on_result=print_result, on_cancel=announce_cancel,
                cancelled=cancelled)
        except DiscoveryCancelled as error:
            announce_cancel([p.name for p in test_files(args.folder)])
            print(str(error), flush=True)
            return 128 + received[0]
        code = report(results, expected, show_output=False)
        return 128 + received[0] if received else code
    finally:
        for signum, handler in old.items():
            signal.signal(signum, handler)


if __name__ == '__main__':
    sys.exit(main())
