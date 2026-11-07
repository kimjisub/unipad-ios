"""Check startup state transitions without reaching another simulator."""
import json
import subprocess
import unittest
from unittest.mock import patch

from simulator_startup import prepare


class SimulatorStartupTests(unittest.TestCase):
    def run_for(self, action, state='Shutdown', available=True, selected='selected', error=None):
        devices = {'devices': {'runtime': [
            {'udid': 'other', 'state': 'Shutdown', 'isAvailable': True},
            {'udid': 'selected', 'state': state, 'isAvailable': available},
        ]}}
        listing = subprocess.CompletedProcess([], 0, stdout=json.dumps(devices))
        runner = patch('simulator_startup.subprocess.run')
        with runner as run:
            run.side_effect = [listing, error or subprocess.CompletedProcess([], 0)]
            prepare(action, selected)
            return [call.args[0] for call in run.call_args_list]

    def test_start_boots_only_the_selected_shutdown_device(self):
        self.assertEqual(self.run_for('start')[-1], ['xcrun', 'simctl', 'boot', 'selected'])

    def test_start_does_not_restart_booting_or_booted_devices(self):
        for state in ('Booting', 'Booted'):
            with self.subTest(state=state):
                self.assertEqual(len(self.run_for('start', state)), 1)

    def test_wait_checks_readiness_for_the_selected_device(self):
        for state in ('Booting', 'Booted'):
            with self.subTest(state=state):
                self.assertEqual(self.run_for('wait', state)[-1],
                                 ['xcrun', 'simctl', 'bootstatus', 'selected', '-b'])

    def test_wait_never_defers_boot_until_the_test_step(self):
        with self.assertRaisesRegex(RuntimeError, 'start it before building'):
            self.run_for('wait')

    def test_missing_or_unavailable_device_does_not_fall_back_to_another_device(self):
        for kwargs in ({'selected': 'missing'}, {'available': False}):
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(RuntimeError, 'not available'):
                self.run_for('start', **kwargs)

    def test_shutting_down_device_is_not_restarted(self):
        with self.assertRaisesRegex(RuntimeError, 'Shutting Down'):
            self.run_for('start', 'Shutting Down')

    def test_boot_and_readiness_failures_fail_the_step(self):
        for action, state in (('start', 'Shutdown'), ('wait', 'Booting')):
            with self.subTest(action=action), self.assertRaises(subprocess.CalledProcessError):
                self.run_for(action, state, error=subprocess.CalledProcessError(1, 'simctl'))


if __name__ == '__main__':
    unittest.main()
