#!/usr/bin/env python3
"""Virtual Matrix hold/release and clear, with screenshots from the real play screen.

Acquire/release the simulator through the device harness. This checks CoreMIDI,
the app and returning LED messages, not physical USB or audible output.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid

from virtual_launchpad_roundtrip import Run, ROOT, fixture, packets, snapshot


def release_error(sent, received, observed_until):
    tx, rx = packets(sent), packets(received)
    if [(s, n, v) for _, s, n, v in tx] != [(0x90, 64, 127), (0x90, 64, 0)]:
        return 'missing ordered press and velocity-zero release'
    press, release = tx[0][0], tx[1][0]
    if not any(press <= t < release and n == 64 and v > 0 for t, _, n, v in rx):
        return 'the held pad never returned a nonzero light'
    # Observe an endless 100 ms animation for at least a second after release.
    # Inspect before exit: the exit's clear must not hide a failed release.
    if observed_until < release + 1:
        return 'release observation is incomplete'
    tail = [(n, v) for t, _, n, v in rx if release + 0.25 <= t <= observed_until and n == 64]
    if any(v > 0 for _, v in tail):
        return 'the released pad continued its endless lights'
    if not any(t >= release and n == 64 and v == 0 for t, _, n, v in rx):
        return 'the released pad did not return a light-off'
    return None


def uncleared_round_lights(received, exit_time):
    # Require an off sent after the exit action began, not an old off from entry.
    # Home may then light its own navigation buttons; that does not undo the clear.
    cleared = {n for t, status, n, value in packets(received)
               if t >= exit_time and status == 0x91 and value == 0}
    return [n for n in list(range(28, 36)) + list(range(100, 124)) if n not in cleared]


class MatrixRun(Run):
    def execute(self):
        self.report['scope'] = 'virtual Matrix: held pad, velocity-zero release, screen exit and 32 round lights'
        self.report['commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        self.report['diff'] = subprocess.check_output(['git', 'diff', '--stat'], cwd=ROOT, text=True)
        for bundle in [self.bundle, self.bundle + '.xctrunner']:
            if self.container(bundle, required=False) is not None:
                raise RuntimeError(f'{bundle} already installed')
        self.shared = self.container('kim.jisub.unipad', required=False)
        if self.shared:
            stopped = subprocess.run(self.sim + ['terminate', self.args.simulator, 'kim.jisub.unipad'],
                                     capture_output=True, text=True, timeout=30)
            if stopped.returncode and not any(message in stopped.stderr.lower()
                                              for message in ['no such process', 'not running', 'nothing to terminate']):
                raise RuntimeError(stopped.stderr)
        self.before = snapshot(self.shared)
        self.report['shared_before'] = self.before
        base = ['xcodebuild', '-project', 'unipad.xcodeproj', '-scheme', 'unipad',
                '-configuration', 'Debug', '-destination', f'platform=iOS Simulator,id={self.args.simulator},arch=arm64',
                '-derivedDataPath', str(self.args.derived_data.resolve()),
                '-onlyUsePackageVersionsFromResolvedFile', '-parallel-testing-enabled', 'NO',
                'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'UNIPAD_WARNINGS_AS_ERRORS=YES',
                f'PRODUCT_BUNDLE_IDENTIFIER={self.bundle}']
        self.command(base + ['build-for-testing'], 'build.log', 900)
        app = self.args.derived_data.resolve() / 'Build/Products/Debug-iphonesimulator/unipad.app'
        self.install_attempts.add(self.bundle)
        self.command(self.sim + ['install', self.args.simulator, str(app)], 'install.log')
        token = str(uuid.uuid4())
        test_root = Path(self.container(self.bundle)) / 'Documents/ReleaseTests' / token
        fixture(test_root)
        pack = test_root / 'UniPack/VirtualMIDI'
        for led in (pack / 'keyLed').iterdir():
            led.unlink()
        # Keep the held light steady so a screenshot cannot land between flashes.
        (pack / 'keyLed/1 1 1 0').write_text('on 1 1 a 5\ndelay 100\n')
        log = self.output / 'app.log'
        logger = self.start(['zsh', 'ci/virtual-launchpad.sh', self.args.simulator, '--log', str(log)], 'app.log')
        self.wait(lambda: 'collector: pid=' in self.read(log), 60, 'log collector', logger)
        self.collector_pid = int(re.search(r'collector: pid=(\d+)', self.read(log))[1])
        environment = dict(os.environ, UNIPAD_VIRTUAL_CONTROLLER='matrix')
        helper = self.start(['zsh', 'ci/virtual-launchpad.sh', self.args.simulator, '300',
                             str(self.output / 'arrivals.txt'), str(self.output / 'send'), str(self.output / 'sent.txt')],
                            'device.log', environment)
        self.wait(lambda: 'started: pid=' in self.read(self.output / 'device.log'), 60, 'virtual Matrix process', helper)
        self.device_pid = int(re.search(r'started: pid=(\d+)', self.read(self.output / 'device.log'))[1])
        self.wait(lambda: 'ready: pid=' in self.read(self.output / 'device.log'), 60, 'virtual Matrix', helper)
        self.device_pid = int(re.search(r'ready: pid=(\d+)', self.read(self.output / 'device.log'))[1])
        for key, value in {'DIR': str(self.output), 'TOKEN': token, 'ORDER': 'matrix'}.items():
            environment['TEST_RUNNER_UNIPAD_MIDI_ROUNDTRIP_' + key] = value
        self.install_attempts.add(self.bundle + '.xctrunner')
        test = self.start(base + ['test-without-building', '-only-testing:unipadUITests/VirtualLaunchpadRoundTripUITests',
                                 '-collect-test-diagnostics', 'never', '-resultBundlePath', str(self.output / 'UI.xcresult')],
                          'ui.log', environment)
        def observe():
            sent = self.read(self.output / 'sent.txt')
            received = self.read(self.output / 'arrivals.txt')
            tx, rx = packets(sent), packets(received)
            if tx and any(t >= tx[0][0] and n == 64 and v > 0 for t, _, n, v in rx):
                (self.output / 'held').touch()
            if len(tx) == 2 and not (self.output / 'midi-complete').exists():
                # Simulator MIDI times and Python's monotonic clock share mach_absolute_time.
                now = time.monotonic()
                if now >= tx[1][0] + 1.1:
                    (self.output / 'release-arrivals.txt').write_text(received)
                    self.report['release_error'] = release_error(sent, received, now)
                    self.report['release_observed_until'] = now
                    (self.output / 'midi-complete').touch()
            return test.poll() is not None
        self.wait(observe, 240, 'Matrix screen and MIDI exchange', test)
        if test.returncode or not (self.output / 'ui-complete').exists():
            raise RuntimeError(f'UI check failed ({test.returncode})')
        exit_time = float((self.output / 'exit-time').read_text())
        deadline = time.monotonic() + 10
        missing = uncleared_round_lights(self.read(self.output / 'arrivals.txt'), exit_time)
        while missing and time.monotonic() < deadline:
            time.sleep(0.1)
            missing = uncleared_round_lights(self.read(self.output / 'arrivals.txt'), exit_time)
        self.report['exit_time'] = exit_time
        self.report['round_lights_not_cleared'] = missing
        if self.report.get('release_error') or missing:
            raise ValueError(f'release={self.report.get("release_error")}; round lights not cleared={missing}')
        self.report['checks'] = ['held pad lit', 'velocity-zero release stopped lights', 'all 32 round lights cleared on exit']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=1500)
    args = parser.parse_args()
    run = MatrixRun(args)
    def interrupted(sig, frame):
        raise TimeoutError(f'interrupted ({sig}) during {run.report.get("active_wait", "setup")}')
    stops = [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]
    for sig in stops + [signal.SIGALRM]:
        signal.signal(sig, interrupted)
    signal.alarm(args.timeout)
    code = 0
    try:
        run.execute()
        run.report['result'] = 'passed'
    except Exception as error:
        run.report.update(result='failed', error=str(error))
        code = 1
    finally:
        signal.alarm(0)
        for sig in stops:
            signal.signal(sig, signal.SIG_IGN)
        try:
            run.cleanup()
        except Exception as error:
            run.report.update(result='failed', cleanup_error=str(error))
            code = 1
        run.save()
    print(json.dumps({k: v for k, v in run.report.items() if k in
                      ['result', 'error', 'cleanup_error', 'checks', 'release_error', 'round_lights_not_cleared']}, indent=2))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
