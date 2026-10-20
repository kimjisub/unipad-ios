#!/usr/bin/env python3
"""Check notification permission, background return and cold launch on a lent iPhone.

The caller acquires/releases the simulator through its device harness. Uses a
separate fresh test app, fake Firebase configuration and local download fixtures.
Does not test APNs/FCM delivery from a real Firebase server.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'io.unipad.tests.notifications.unipad'


def stop_process(process):
    if process.poll() is not None:
        return
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True, timeout=10)
    pairs = [tuple(map(int, row.split())) for row in rows.splitlines()]
    owned = {process.pid}
    while True:
        more = {pid for pid, parent in pairs if parent in owned} - owned
        if not more:
            break
        owned.update(more)
    for pid in owned - {process.pid}:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    process.terminate()
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


def assess_runtime(log):
    launches = re.findall(r'unipad\[(\d+):[^\]]+\].*local_only=(YES|NO) launch_override=(YES|NO)', log)
    if len(launches) != 2:
        raise ValueError(f'expected two app launches, got {launches}')
    initial, cold = launches
    if initial[1:] != ('YES', 'YES') or cold[1:] != ('YES', 'NO') or initial[0] == cold[0]:
        raise ValueError(f'local-only must survive a new process without arguments: {launches}')
    return {'initial_pid': int(initial[0]), 'cold_pid': int(cold[0]), 'cold_local_only': True,
            'cold_launch_override': False}


class Check:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.report = {'command': __import__('sys').argv, 'commands': [], 'result': 'failed',
                       'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                       'scope': 'synthetic simulator notifications only; no real APNs/FCM delivery'}
        (self.output / 'source.patch').write_text(subprocess.check_output(['git', 'diff', 'HEAD'], cwd=ROOT, text=True))
        self.sim = ['xcrun', 'simctl']
        self.ui = None
        self.runner_bundle = None
        self.owns_app = False

    def save(self):
        (self.output / 'result.json').write_text(json.dumps(self.report, indent=2) + '\n')

    def command(self, command, name, timeout=120, required=True):
        entry = {'command': command, 'log': name}
        self.report['commands'].append(entry)
        self.save()
        started = time.monotonic()
        with (self.output / name).open('w') as log:
            proc = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            entry['pid'] = proc.pid
            self.save()
            try:
                proc.wait(timeout=timeout)
            finally:
                stop_process(proc)
        entry.update(exit_code=proc.returncode, seconds=round(time.monotonic() - started, 2))
        self.save()
        if required and proc.returncode:
            raise RuntimeError(f'{name}: exit {proc.returncode}')
        return (self.output / name).read_text(errors='replace')

    def execute(self):
        installed = subprocess.run(self.sim + ['get_app_container', self.args.simulator, BUNDLE, 'data'],
                                   capture_output=True, text=True, timeout=30)
        if installed.returncode == 0:
            raise RuntimeError('test app already installed; refusing to replace its data')
        if not any(text in installed.stderr for text in ['No such file', 'not installed']):
            raise RuntimeError(installed.stderr)
        base = ['xcodebuild', '-quiet', '-project', 'unipad.xcodeproj', '-scheme', 'unipad',
                '-configuration', 'Debug', '-destination', f'platform=iOS Simulator,id={self.args.simulator},arch=arm64',
                '-derivedDataPath', str(self.args.derived_data.resolve()),
                '-clonedSourcePackagesDirPath', str(self.args.derived_data.resolve().parent / 'packages'),
                '-onlyUsePackageVersionsFromResolvedFile', '-parallel-testing-enabled', 'NO',
                'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'UNIPAD_WARNINGS_AS_ERRORS=YES',
                # Expand per target: a global constant gives the app and both test bundles
                # the same identifier, making notification routing ambiguous.
                'PRODUCT_BUNDLE_IDENTIFIER=io.unipad.tests.notifications.$(PRODUCT_NAME:rfc1034identifier)']
        self.command(base + ['build-for-testing'], 'build.log', timeout=900)
        app = self.args.derived_data.resolve() / 'Build/Products/Debug-iphonesimulator/unipad.app'
        runner = app.parent / 'unipadUITests-Runner.app'
        products = [app, app / 'PlugIns/unipadTests.xctest', runner,
                    runner / 'PlugIns/unipadUITests.xctest']
        identifiers = [plistlib.loads((product / 'Info.plist').read_bytes())['CFBundleIdentifier']
                       for product in products]
        self.report['bundle_identifiers'] = dict(zip(['app', 'unit_tests', 'ui_runner', 'ui_tests'], identifiers))
        self.runner_bundle = identifiers[2]
        if identifiers[0] != BUNDLE or len(set(identifiers)) != 4 or not all(
                value.startswith('io.unipad.tests.notifications.') for value in identifiers):
            raise ValueError(f'expected four separate test bundle identifiers: {identifiers}')
        # Even the negative control must never configure the production Firebase project.
        self.command(['python3', 'ci/firebase_fixture.py', str(app / 'GoogleService-Info.plist')], 'fake-config.log')
        self.owns_app = True
        self.command(self.sim + ['install', self.args.simulator, str(app)], 'install.log')
        token = str(uuid.uuid4())
        env = dict(os.environ, TEST_RUNNER_UNIPAD_NOTIFICATION_DIR=str(self.output),
                   TEST_RUNNER_UNIPAD_NOTIFICATION_TOKEN=token)
        started = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        command = base + ['test-without-building', '-only-testing:unipadUITests/NotificationRoundTripUITests',
                          '-collect-test-diagnostics', 'never', '-resultBundlePath', str(self.output / 'UI.xcresult')]
        self.report['ui_command'] = command
        with (self.output / 'ui.log').open('w') as log:
            self.ui = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=env)
            self.report['ui_pid'] = self.ui.pid
            self.save()
            deadline = time.monotonic() + 300
            sent = set()
            try:
                while self.ui.poll() is None:
                    if time.monotonic() > deadline:
                        raise TimeoutError('notification UI test exceeded 300 seconds')
                    for mode in ['background', 'cold']:
                        if mode not in sent and (self.output / f'ready-{mode}').exists():
                            payload = self.output / f'{mode}.apns'
                            payload.write_text(json.dumps({'aps': {'alert': {'title': 'UniPad',
                                                                        'body': f'UniPad {mode} {token}'},
                                                                  'sound': 'default'}}))
                            self.command(self.sim + ['push', self.args.simulator, BUNDLE, str(payload)], f'push-{mode}.log')
                            (self.output / f'pushed-{mode}').touch()
                            sent.add(mode)
                    time.sleep(0.2)
            finally:
                self.stop_ui()
        self.report['ui_exit_code'] = self.ui.returncode
        runtime = self.command(self.sim + ['spawn', self.args.simulator, 'log', 'show', '--style', 'compact',
                                          '--start', started, '--predicate',
                                          f'subsystem == "{BUNDLE}" AND category == "FirebaseRuntime"'], 'runtime.log')
        if self.ui.returncode != 0:
            raise RuntimeError(f'notification UI failed: exit {self.ui.returncode}; see ui.log')
        for mode in ['background', 'cold']:
            if not (self.output / f'returned-{mode}').exists():
                raise ValueError(f'{mode} notification return was not checked')
        self.report['runtime'] = assess_runtime(runtime)
        self.report['result'] = 'passed'

    def stop_ui(self):
        if self.ui is not None:
            stop_process(self.ui)

    def cleanup(self):
        self.stop_ui()
        if self.owns_app:
            for bundle in [self.runner_bundle, BUNDLE]:
                self.command(self.sim + ['terminate', self.args.simulator, bundle], f'terminate-{bundle}.log', required=False)
                self.command(self.sim + ['uninstall', self.args.simulator, bundle], f'uninstall-{bundle}.log')
            self.report['test_app_removed'] = True
        self.save()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='new evidence directory')
    args = parser.parse_args()
    check = Check(args)

    def interrupted(sig, frame):
        raise InterruptedError(f'interrupted by signal {sig}')

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        check.execute()
    except Exception as error:
        check.report['error'] = str(error)
    finally:
        try:
            check.cleanup()
        except Exception as error:
            check.report.update(result='failed', cleanup_error=str(error))
            check.save()
    print(json.dumps(check.report, indent=2))
    return 0 if check.report['result'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
