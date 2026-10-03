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
    def select(self, devices):
        workflow = (Path(__file__).parent.parent / '.github/workflows/ios-checks.yml').read_text()
        ui_job = workflow.split('  ui-tests:', 1)[1]
        source = textwrap.dedent(ui_job.split("python3 - <<'PY'\n", 1)[1].split('\n          PY', 1)[0])
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            with patch.dict(os.environ, {'GITHUB_OUTPUT': str(output)}), \
                 patch('subprocess.check_output', return_value=json.dumps({'devices': devices}).encode()), \
                 contextlib.redirect_stdout(io.StringIO()):
                exec(compile(source, 'workflow-ui-selector', 'exec'), {})
            return output.read_text()

    def device(self, name='iPhone 17 Pro', available=True):
        return {'name': name, 'isAvailable': available, 'udid': 'measured-phone'}

    def test_accepts_ios_26_2_installed_on_macos_15_runner(self):
        self.assertEqual(self.select({'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [self.device()]}),
                         'udid=measured-phone\n')

    def test_accepts_local_ios_26_3(self):
        self.assertEqual(self.select({'com.apple.CoreSimulator.SimRuntime.iOS-26-3': [self.device()]}),
                         'udid=measured-phone\n')

    def test_rejects_unmeasured_phone_unavailable_phone_and_ios_27(self):
        for inventory in [
            {'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [self.device(name='iPhone 17')]},
            {'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [self.device(available=False)]},
            {'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [self.device()]},
            {},
        ]:
            with self.subTest(inventory=inventory), self.assertRaises(SystemExit):
                self.select(inventory)


if __name__ == '__main__':
    unittest.main()
