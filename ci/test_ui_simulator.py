"""Exercise the workflow's actual selector against installed runner inventories."""
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import textwrap
import unittest
from unittest.mock import patch


class UISimulatorTests(unittest.TestCase):
    def select(self, devices, *, runtimes=None, device_types=None, hosted=False):
        workflow = (Path(__file__).parent.parent / '.github/workflows/ios-checks.yml').read_text()
        ui_job = workflow.split('  ui-tests:', 1)[1]
        source = textwrap.dedent(ui_job.split("python3 - <<'PY'\n", 1)[1].split('\n          PY', 1)[0])
        def simctl(args, **kwargs):
            if args == ['xcrun', 'simctl', 'list', 'devices', 'available', '--json']:
                return json.dumps({'devices': devices}).encode()
            if args == ['xcrun', 'simctl', 'list', 'runtimes', '--json']:
                return json.dumps({'runtimes': runtimes or []}).encode()
            if args == ['xcrun', 'simctl', 'list', 'devicetypes', '--json']:
                return json.dumps({'devicetypes': device_types or []}).encode()
            self.assertEqual(args, ['xcrun', 'simctl', 'create', 'UniPad UI reference',
                                   'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
                                   'com.apple.CoreSimulator.SimRuntime.iOS-27-0'])
            return 'created-reference\n'

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            with patch.dict(os.environ, {'GITHUB_OUTPUT': str(output), 'GITHUB_ACTIONS': 'true' if hosted else 'false'}), \
                 patch('subprocess.check_output', side_effect=simctl), \
                 contextlib.redirect_stdout(io.StringIO()):
                exec(compile(source, 'workflow-ui-selector', 'exec'), {})
            return output.read_text()

    def device(self, name='iPhone 17 Pro', available=True):
        return {'name': name, 'isAvailable': available, 'udid': 'measured-phone'}

    def test_accepts_ios_27_on_xcode_27_runner(self):
        self.assertEqual(self.select({'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [self.device()]}),
                         'udid=measured-phone\n')

    def test_selects_ios_27_when_older_runtimes_are_also_installed(self):
        self.assertEqual(self.select({'com.apple.CoreSimulator.SimRuntime.iOS-26-3': [self.device(name='iPhone 17')],
                                     'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [self.device()]}),
                         'udid=measured-phone\n')

    def test_creates_same_reference_on_hosted_runner_without_precreated_phone(self):
        # The 20260928.0222 runner image has iOS 27 but precreates iPhone 18 Pro.
        self.assertEqual(self.select(
            {'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [self.device(name='iPhone 18 Pro')]},
            runtimes=[{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                       'isAvailable': True}],
            device_types=[{'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}],
            hosted=True), 'udid=created-reference\n')

    def test_hosted_creation_requires_installed_reference_profile_and_exact_runtime(self):
        for runtimes, device_types in [
            ([], [{'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}]),
            ([{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'isAvailable': False}],
             [{'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}]),
            ([{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'isAvailable': True}], []),
            ([{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-1', 'isAvailable': True}],
             [{'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}]),
        ]:
            with self.subTest(runtimes=runtimes, device_types=device_types), self.assertRaises(SystemExit):
                self.select({}, runtimes=runtimes, device_types=device_types, hosted=True)

    def test_local_selection_never_creates_a_device(self):
        with self.assertRaises(SystemExit):
            self.select({},
                        runtimes=[{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
                                   'isAvailable': True}],
                        device_types=[{'identifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}])

    def test_rejects_unmeasured_unavailable_and_pre_voiceover_runtime(self):
        for inventory in [
            {'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [self.device(name='iPhone 17')]},
            {'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [self.device(available=False)]},
            {'com.apple.CoreSimulator.SimRuntime.iOS-26-3': [self.device()]},
            {},
        ]:
            with self.subTest(inventory=inventory), self.assertRaises(SystemExit):
                self.select(inventory)


if __name__ == '__main__':
    unittest.main()
