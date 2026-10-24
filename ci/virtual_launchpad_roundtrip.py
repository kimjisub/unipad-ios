#!/usr/bin/env python3
"""Check virtual Launchpad MK2 connection, input order, and returning lights.

Usage: python3 ci/virtual_launchpad_roundtrip.py --simulator UDID --output DIR
       --derived-data DIR
The caller must acquire/release UDID through its device harness. Runs in the
foreground; all children are owned, bounded, and stopped by recorded PID on exit.
Installs a separate test app, uses an isolated fixture library, then uninstalls it.
Closes the normal app first so it cannot react to the injected MIDI notes.
The normal app's Documents/UniPack and preferences are compared before/after.

Does NOT verify physical USB, real hardware latency, or models other than MK2.
No production Firebase configuration: Debug + -UniPadFirebaseLocalOnly YES selects
local stubs; the local AnalyticsLocal platform marker is required as evidence.
UI tests are opt-in and are not added to required CI checks.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]


def packets(text):
    result = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 4:
            continue
        when = float(fields[0])
        status, data = None, []
        for field in fields[1:]:
            byte = int(field, 16)
            if byte >= 0xF8:  # Realtime messages do not cancel running status.
                continue
            if byte >= 0x80:
                status, data = byte, []
            elif status is not None:
                data.append(byte)
                if len(data) == 2:
                    if status & 0xF0 in (0x80, 0x90, 0xB0):
                        result.append((when, status, *data))
                    data = []
    return result


def scoped_log(text, bundle):
    """The simulator may have another UniPad process. Never combine its input/events."""
    pids = set(re.findall(r'unipad\[(\d+):[^\]]+\].*\[' + re.escape(bundle)
                          + r':AnalyticsLocal\] user_property platform=ios', text))
    if len(pids) != 1:
        raise ValueError(f'waiting for exactly one local-only test app process, got {sorted(pids)}')
    pid = int(next(iter(pids)))
    return '\n'.join(line for line in text.splitlines() if f'unipad[{pid}:' in line), pid


def assess_pro_initialization(received):
    message, modes = [], []
    for line in received.splitlines():
        fields = line.split()
        if len(fields) < 2:
            continue
        when = float(fields[0])
        for field in fields[1:]:
            byte = int(field, 16)
            if byte == 0xF0:
                message = [byte]
            elif message:
                message.append(byte)
                if byte == 0xF7:
                    if message[:6] == [0xF0, 0, 0x20, 0x29, 2, 0x10] and message[6:8] in ([0x21, 0], [0x22, 0]):
                        modes.append((when, message[6]))
                    message = []
    if [command for _, command in modes].count(0x21) != 2 or [command for _, command in modes].count(0x22) != 2:
        raise ValueError('waiting for every Pro mode message')
    lights = packets(received)
    if not lights:
        raise ValueError('waiting for Pro lights after initialization')
    if lights[0][0] < max(t for t, _ in modes) + 0.5:
        raise ValueError('Pro lights preceded the final mode message and settling delay')


def assess(log, sent, received, order, controller='mk2'):
    """Reject send-only evidence, old/unrelated lights, and duplicate analytics."""
    if 'user_property platform=ios' not in log:
        raise ValueError('waiting for local-only AnalyticsLocal platform marker')
    if controller == 'pro':
        assess_pro_initialization(received)
    events = re.findall(r'event play_first_input ([^\n]*)', log)
    if len(events) != 1 or not re.search(rf'\binput_source={order}\b', events[0]):
        raise ValueError(f'expected exactly one {order} first input, got {events}')
    tx, rx = packets(sent), packets(received)
    if [(s, n, v) for _, s, n, v in tx] != [(0x90, 81, 127), (0x90, 81, 0),
                                                        (0x90, 82, 127), (0x90, 82, 0)]:
        raise ValueError('expected ordered notes 81/82 with releases')
    inputs = [(int(n), int(v)) for n, v in re.findall(r'MIDI IN: cmd=9 sig=-112 note=(\d+) vel=(\d+)', log)]
    if inputs != [(81, 127), (81, 0), (82, 127), (82, 0)]:
        raise ValueError(f'waiting for ordered app receipt notes 81/82 and releases, got {inputs}')
    for when, _, note, velocity in tx:
        if f'MIDI IN: cmd=9 sig=-112 note={note} vel={velocity}' not in log:
            raise ValueError(f'waiting for app receipt note={note} velocity={velocity}')
        if velocity and not any(t >= when and s == 0x90 and n == note and v > 0 for t, s, n, v in rx):
            raise ValueError(f'waiting for nonzero light after note={note}')


def snapshot(container):
    if container is None:
        return {'installed': False}
    root = Path(container)
    library = root / 'Documents/UniPack'
    listing = sorted(p.relative_to(library).as_posix() for p in library.rglob('*'))
    prefs = root / 'Library/Preferences/kim.jisub.unipad.plist'
    return {'installed': True, 'library_exists': library.exists(), 'library': listing,
            'preferences_sha256': hashlib.sha256(prefs.read_bytes()).hexdigest() if prefs.exists() else None}


def fixture(root):
    pack = root / 'UniPack/VirtualMIDI'
    (pack / 'sounds').mkdir(parents=True)
    (pack / 'keyLed').mkdir()
    (pack / 'info').write_text('title=Virtual MIDI Fixture\nproducerName=Tests\nbuttonX=8\nbuttonY=8\nchain=1\nsquareButton=true\n')
    (pack / 'keySound').write_text('1 1 1 silence.wav\n1 1 2 silence.wav\n')
    for column, color in [(1, 5), (2, 9)]:
        (pack / f'keyLed/1 1 {column} 1').write_text(f'on 1 {column} a {color}\ndelay 100\noff 1 {column}\n')
    with wave.open(str(pack / 'sounds/silence.wav'), 'wb') as sound:
        sound.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
        sound.writeframes(bytes(960))


class Run:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.deadline = time.monotonic() + args.timeout
        self.children = []
        self.handles = []
        self.report = {'command': __import__('sys').argv, 'checks': [], 'children': [],
                       'scope': 'virtual MK2; no physical USB, hardware latency, or other models'}
        self.controller = getattr(args, 'controller', 'mk2')
        if self.controller == 'pro':
            self.report['scope'] = 'virtual original Pro; initialization order and MIDI round trip, no physical USB or hardware latency'
        # Stable across invocations so changing a bundle ID does not rebuild every package.
        # A pre-existing installation is preserved and rejected before doing any device work.
        self.bundle = 'io.unipad.tests.virtual-midi'
        self.install_attempts = set()
        self.sim = ['xcrun', 'simctl']

    def start(self, command, name, env=None):
        handle = (self.output / name).open('w')
        self.handles.append(handle)
        child = subprocess.Popen(command, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT, env=env)
        self.children.append(child)
        self.report['children'].append({'pid': child.pid, 'command': command})
        self.save()
        return child

    def stop(self, child):
        if child.poll() is not None:
            return
        # Ask only for this wrapper's children, rather than formatting the whole Mac's
        # process table. Keep every discovered PID so a later lookup failure still reaps it.
        owned = {child.pid}
        pending = [child.pid]
        try:
            while pending:
                parent = pending.pop()
                result = subprocess.run(['pgrep', '-P', str(parent)], capture_output=True,
                                        text=True, timeout=10)
                if result.returncode not in (0, 1):
                    raise RuntimeError(f'cannot list children of {parent}: {result.stderr}')
                more = {int(pid) for pid in result.stdout.split()} - owned
                owned.update(more)
                pending.extend(more)
        finally:
            descendants = owned - {child.pid}
            try:
                self.report.setdefault('descendant_pids', []).extend(sorted(descendants))
                self.save()
            finally:
                for pid in descendants:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=10)

    def wait(self, predicate, seconds, description, child=None):
        self.report['active_wait'] = description
        deadline = min(self.deadline, time.monotonic() + seconds)
        while time.monotonic() < deadline:
            if predicate():
                self.report.pop('active_wait', None)
                return
            if child is not None and child.poll() is not None:
                raise RuntimeError(f'{description}: process exited {child.returncode}')
            time.sleep(0.1)
        raise TimeoutError(f'timed out waiting for {description} ({seconds}s, overall {self.args.timeout}s)')

    def command(self, command, name, seconds=180, env=None):
        child = self.start(command, name, env)
        self.wait(lambda: child.poll() is not None, seconds, name)
        if child.returncode:
            raise RuntimeError(f'{name}: exit {child.returncode}')
        return (self.output / name).read_text()

    def save(self):
        (self.output / 'result.json').write_text(json.dumps(self.report, indent=2) + '\n')

    def container(self, bundle, required=True):
        proc = subprocess.run(self.sim + ['get_app_container', self.args.simulator, bundle, 'data'],
                              text=True, capture_output=True, timeout=30)
        if proc.returncode:
            if not required and ('No such file or directory' in proc.stderr or 'is not installed' in proc.stderr):
                return None
            raise RuntimeError(proc.stderr)
        return proc.stdout.strip()

    def execute(self):
        self.report['commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        for bundle in [self.bundle, self.bundle + '.xctrunner']:
            if self.container(bundle, required=False) is not None:
                raise RuntimeError(f'{bundle} already installed; refusing to replace its data. A run stopped '
                                   f'by force leaves it: xcrun simctl uninstall {self.args.simulator} {bundle}')
        self.shared = self.container('kim.jisub.unipad', required=False)
        if self.shared is not None:
            command = self.sim + ['terminate', self.args.simulator, 'kim.jisub.unipad']
            stopped = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.report['close_shared_app'] = {'command': command, 'exit_code': stopped.returncode,
                                                'stderr': stopped.stderr}
            if stopped.returncode and not any(message in stopped.stderr.lower()
                                              for message in ['not running', 'nothing to terminate']):
                raise RuntimeError('could not close the shared app before injecting MIDI: ' + stopped.stderr)
            self.shared = self.container('kim.jisub.unipad', required=False)
        self.report['shared_container_before'] = self.shared
        self.before = snapshot(self.shared)
        self.report['shared_before'] = self.before
        base = ['xcodebuild', '-project', 'unipad.xcodeproj', '-scheme', 'unipad',
                '-configuration', 'Debug', '-destination', f'platform=iOS Simulator,id={self.args.simulator},arch=arm64',
                '-derivedDataPath', str(self.args.derived_data.resolve()),
                '-clonedSourcePackagesDirPath', str(self.args.derived_data.resolve().parent / 'packages'),
                '-onlyUsePackageVersionsFromResolvedFile', '-parallel-testing-enabled', 'NO',
                'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'UNIPAD_WARNINGS_AS_ERRORS=YES',
                f'PRODUCT_BUNDLE_IDENTIFIER={self.bundle}']
        self.command(base + ['build-for-testing'], 'build.log', 600)
        app = self.args.derived_data.resolve() / 'Build/Products/Debug-iphonesimulator/unipad.app'
        self.install_attempts.add(self.bundle)
        self.command(self.sim + ['install', self.args.simulator, str(app)], 'install.log')
        for order in ['midi', 'screen']:
            directory = self.output / order
            directory.mkdir()
            token = str(uuid.uuid4())
            # XCTest can migrate the data container when reinstalling the app. Never retain
            # its old absolute path across test-without-building invocations.
            data = Path(self.container(self.bundle))
            test_root = data / 'Documents/ReleaseTests' / token
            self.report.setdefault('fixture_containers', {})[order] = str(data)
            fixture(test_root)
            log = directory / 'app.log'
            logger = self.start(['zsh', 'ci/virtual-launchpad.sh', self.args.simulator, '--log', str(log)],
                                f'{order}/app.log')
            self.wait(lambda: 'collector: pid=' in self.read(log), 60, 'log collector process', logger)
            self.collector_pid = int(re.search(r'collector: pid=(\d+)', self.read(log))[1])
            self.report['children'].append({'pid': self.collector_pid, 'kind': 'log-collector'})
            helper = None
            if not self.args.without_device:
                helper = self.start(['zsh', 'ci/virtual-launchpad.sh', self.args.simulator, '300',
                                     str(directory / 'arrivals.txt'), str(directory / 'send'), str(directory / 'sent.txt')],
                                    f'{order}/device.log', dict(os.environ, UNIPAD_VIRTUAL_CONTROLLER=self.controller))
                self.wait(lambda: 'started: pid=' in self.read(directory / 'device.log'), 60, 'virtual device process', helper)
                self.device_pid = int(re.search(r'started: pid=(\d+)', self.read(directory / 'device.log'))[1])
                self.wait(lambda: 'ready: pid=' in self.read(directory / 'device.log'), 60, 'virtual device ready', helper)
                pid = int(re.search(r'ready: pid=(\d+)', self.read(directory / 'device.log'))[1])
                self.report['children'].append({'pid': pid, 'simulator': self.args.simulator, 'kind': 'virtual-device'})
                self.device_pid = pid
            environment = dict(os.environ)
            if self.controller == 'pro':
                environment['TEST_RUNNER_UNIPAD_MIDI_ROUNDTRIP_DEVICE'] = 'Launchpad Pro'
            for key, value in {'DIR': str(directory), 'TOKEN': token, 'ORDER': order}.items():
                environment['TEST_RUNNER_UNIPAD_MIDI_ROUNDTRIP_' + key] = value
            # XCTest installs the runner; cleanup also covers a failed test launch.
            self.install_attempts.add(self.bundle + '.xctrunner')
            test = self.start(base + ['test-without-building', '-only-testing:unipadUITests/VirtualLaunchpadRoundTripUITests',
                                     '-collect-test-diagnostics', 'never', '-resultBundlePath', str(directory / 'UI.xcresult')],
                              f'{order}/ui.log', environment)
            # Do not acknowledge input to XCTest until app receipt and returning lights are present.
            def complete():
                text = self.read(log)
                sent, received = self.read(directory / 'sent.txt'), self.read(directory / 'arrivals.txt')
                try:
                    text, app_pid = scoped_log(text, self.bundle)
                    self.report.setdefault('app_pids', {})[order] = app_pid
                    # The MIDI-first scenario checks screen input later; all MIDI requirements
                    # must already be true when it is allowed to tap the screen.
                    assess(text, sent, received, order, self.controller)
                    self.report.pop('waiting_for', None)
                    (directory / 'midi-complete').touch()
                except ValueError as error:
                    self.report['waiting_for'] = str(error)
                return test.poll() is not None
            self.wait(complete, 240, f'{order} UI and MIDI round trip')
            self.stop_collector()
            self.stop(logger)
            if helper:
                self.stop_device()
                self.stop(helper)
            if test.returncode:
                raise RuntimeError(f'{order} UI failed ({test.returncode}); {self.report.get("waiting_for", "connection wait")}; see ui.log')
            if not (directory / 'ui-complete').exists():
                raise ValueError(f'{order}: UI completion marker missing')
            own_log, _ = scoped_log(self.read(log), self.bundle)
            assess(own_log, self.read(directory / 'sent.txt'), self.read(directory / 'arrivals.txt'), order, self.controller)
            self.report['checks'].append({'order': order, 'local_only': True, 'result': 'passed'})
            self.save()

    @staticmethod
    def read(path):
        return path.read_text(errors='replace') if path.exists() else ''

    def stop_device(self):
        if getattr(self, 'device_pid', None):
            # simctl spawn's helper has its own simulator PID, distinct from simctl on the host.
            # Simulator processes use host PIDs. Signal only the PID reported by our helper.
            try:
                os.kill(self.device_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            self.report.setdefault('stopped_device_pids', []).append(self.device_pid)
            self.device_pid = None

    def stop_collector(self):
        if getattr(self, 'collector_pid', None):
            try:
                os.kill(self.collector_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            self.report.setdefault('stopped_collector_pids', []).append(self.collector_pid)
            self.collector_pid = None

    def remove_test_app(self):
        if not self.install_attempts:
            return
        # Both identifiers were absent at preflight. Remove only installations
        # left by a command that this run actually attempted, including partial failures.
        for bundle in [self.bundle + '.xctrunner', self.bundle]:
            if bundle not in self.install_attempts or self.container(bundle, required=False) is None:
                continue
            subprocess.run(self.sim + ['terminate', self.args.simulator, bundle], capture_output=True, timeout=15)
            subprocess.run(self.sim + ['uninstall', self.args.simulator, bundle], capture_output=True, timeout=30)
            self.report.setdefault('removed_test_bundles', []).append(bundle)
        self.report['test_app_removed'] = all(self.container(bundle, required=False) is None
                                              for bundle in [self.bundle, self.bundle + '.xctrunner'])
        if not self.report['test_app_removed']:
            raise RuntimeError('test app was not removed')

    def cleanup(self):
        errors = []
        try:
            self.stop_device()
            self.stop_collector()
            for child in reversed(self.children):
                try:
                    self.stop(child)
                except Exception as error:
                    errors.append((child.pid, error))
            for pid in set(self.report.get('app_pids', {}).values()):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        finally:
            # A test app left installed shows the file picker a second "UniPad" folder
            # and makes the next run refuse to start, so it goes even when a stop fails.
            self.remove_test_app()
        if getattr(self, 'before', None) is not None:
            # The shared app's container path can migrate too; compare its current data,
            # not a now-missing former location.
            shared_after = self.container('kim.jisub.unipad', required=False)
            self.report['shared_container_after'] = shared_after
            self.report['shared_after'] = snapshot(shared_after)
            self.report['shared_unchanged'] = self.before == self.report['shared_after']
            if not self.report['shared_unchanged']:
                raise RuntimeError('shared UniPack listing or preferences changed')
        self.report['process_exit_codes'] = {str(c.pid): c.poll() for c in self.children}
        for handle in self.handles:
            handle.close()
        if errors:
            self.report['cleanup_errors'] = [{'pid': pid, 'error': str(error)} for pid, error in errors]
        self.save()
        if errors:
            raise errors[0][1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--timeout', type=int, default=1200)
    parser.add_argument('--without-device', action='store_true', help='negative control: connection must fail')
    parser.add_argument('--controller', choices=['mk2', 'pro'], default='mk2')
    args = parser.parse_args()
    run = Run(args)
    def interrupted(sig, frame):
        if sig == signal.SIGALRM:
            raise TimeoutError(f'overall {args.timeout}s limit while waiting for {run.report.get("active_wait", "setup")}')
        raise InterruptedError(f'interrupted by signal {sig}')
    stops = [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]
    for stop in stops + [signal.SIGALRM]:
        signal.signal(stop, interrupted)
    signal.alarm(args.timeout)
    status = 0
    try:
        run.execute()
        run.report['result'] = 'passed'
    except Exception as error:
        run.report['result'] = 'failed'
        run.report['error'] = str(error)
        status = 1
    finally:
        signal.alarm(0)
        # A second stop request must not cut cleanup short; each of its steps is bounded.
        for stop in stops:
            signal.signal(stop, signal.SIG_IGN)
        try:
            run.cleanup()
        except Exception as error:
            run.report['cleanup_error'] = str(error)
            run.report['result'] = 'failed'
            run.save()
            status = 1
    print(json.dumps({key: run.report[key] for key in [
        'result', 'error', 'cleanup_error', 'checks', 'shared_unchanged', 'test_app_removed'
    ] if key in run.report}, indent=2))
    return status


if __name__ == '__main__':
    raise SystemExit(main())
