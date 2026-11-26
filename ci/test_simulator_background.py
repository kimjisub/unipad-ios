"""Keep the CI-only background profile narrow, persistent and verifiable."""
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock

import simulator_background as background
import simulator_settle


UDID = '11111111-2222-3333-4444-555555555555'


class BackgroundTests(unittest.TestCase):
    def test_rejects_service_loaded_only_in_the_discovered_user_domain(self):
        def launchctl(command, **kwargs):
            action = command[5:]
            if action == ['manageruid']:
                return mock.Mock(stdout='707\n', stderr='', returncode=0)
            if action == ['print', 'user/707']:
                return mock.Mock(stdout='user/707 = {\n}\n', stderr='', returncode=0)
            if action[0] == 'print-disabled':
                return mock.Mock(stdout='"com.apple.PosterBoard" => disabled\n'
                                 '"com.apple.chronod" => disabled', stderr='', returncode=0)
            if action[0] == 'print':
                if action[1].startswith('user/707/'):
                    return mock.Mock(stdout='state = running\npid = 1234', stderr='', returncode=0)
                return mock.Mock(stdout='', stderr='Could not find service in domain for system',
                                 returncode=113)
            raise AssertionError(command)

        with mock.patch.object(background.subprocess, 'run', side_effect=launchctl) as run:
            with self.assertRaises(RuntimeError):
                background.verify(UDID)
        self.assertTrue(any(c.args[0][-1] == 'user/707/com.apple.PosterBoard'
                            for c in run.call_args_list))

    def test_merges_only_wallpaper_and_widgets_and_preserves_other_settings(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / f'com.apple.CoreSimulator.SimDevice.{UDID}' / 'disabled.plist'
            path.parent.mkdir()
            path.write_bytes(plistlib.dumps({'other': False, 'com.apple.diagnosticd': False}))
            background.prepare(UDID, Path(folder))
            self.assertEqual(plistlib.loads(path.read_bytes()), {
                'other': False, 'com.apple.diagnosticd': False,
                'com.apple.PosterBoard': True, 'com.apple.chronod': True,
            })
            background.prepare(UDID, Path(folder))
            self.assertEqual(len(plistlib.loads(path.read_bytes())), 4)

    def test_invalid_identifier_and_unreadable_existing_data_are_not_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                background.prepare('../another-device', Path(folder))
            self.assertEqual(list(Path(folder).iterdir()), [])
            path = Path(folder) / f'com.apple.CoreSimulator.SimDevice.{UDID}' / 'disabled.plist'
            path.parent.mkdir()
            path.write_bytes(b'not a plist')
            with self.assertRaises(plistlib.InvalidFileException):
                background.prepare(UDID, Path(folder))
            self.assertEqual(path.read_bytes(), b'not a plist')

    def verification_response(self, command, state='disabled', loaded_status=113):
        action = command[5:]
        if action == ['manageruid']:
            return mock.Mock(stdout='707\n', stderr='', returncode=0)
        if action == ['print', 'user/707']:
            return mock.Mock(stdout='user/707 = {\n}\n', stderr='', returncode=0)
        if action[0] == 'print-disabled':
            return mock.Mock(stdout=f'"com.apple.PosterBoard" => {state}\n'
                             f'"com.apple.chronod" => {state}', stderr='', returncode=0)
        if action[0] == 'print':
            return mock.Mock(stdout='', stderr='Could not find service in domain',
                             returncode=loaded_status)
        raise AssertionError(command)

    def test_verifies_disabled_flags_and_that_neither_service_is_loaded(self):
        for state in ('true', 'disabled'):
            with self.subTest(state=state), mock.patch.object(
                background.subprocess, 'run',
                side_effect=lambda command, **_: self.verification_response(command, state),
            ) as run:
                background.verify(UDID)
            self.assertEqual([c.args[0][5:] for c in run.call_args_list], [
                ['manageruid'], ['print', 'user/707'],
                ['print-disabled', 'system'], ['print', 'system/com.apple.PosterBoard'],
                ['print', 'system/com.apple.chronod'], ['print-disabled', 'user/707'],
                ['print', 'user/707/com.apple.PosterBoard'], ['print', 'user/707/com.apple.chronod'],
            ])

    def test_missing_flag_or_loaded_service_fails_verification(self):
        for state, status in [('false', 113), ('enabled', 113), ('true', 0), ('disabled', 0)]:
            with self.subTest(state=state, status=status), mock.patch.object(
                background.subprocess, 'run',
                side_effect=lambda command, **_: self.verification_response(command, state, status),
            ):
                with self.assertRaises(RuntimeError):
                    background.verify(UDID)

    def test_user_domain_and_service_query_errors_are_not_treated_as_absence(self):
        failures = [
            (['manageruid'], '0', '', 0),
            (['manageruid'], 'invalid', '', 0),
            (['manageruid'], '707', '', 5),
            (['print', 'user/707'], '', 'Could not find domain', 113),
            (['print-disabled', 'user/707'], '', 'Permission denied', 1),
            (['print', 'user/707/com.apple.PosterBoard'], '', 'Could not find domain', 113),
            (['print', 'user/707/com.apple.PosterBoard'], '', 'Permission denied', 3),
            (['print', 'user/707/com.apple.PosterBoard'], '', 'Could not find service', 5),
        ]
        for action, stdout, stderr, status in failures:
            def launchctl(command, **kwargs):
                if command[5:] == action:
                    return mock.Mock(stdout=stdout, stderr=stderr, returncode=status)
                return self.verification_response(command)
            with self.subTest(action=action, status=status, stderr=stderr), mock.patch.object(
                background.subprocess, 'run', side_effect=launchctl,
            ):
                with self.assertRaises(RuntimeError):
                    background.verify(UDID)

    def test_profile_is_prepared_before_boot_and_verified_after_bootstatus(self):
        events = []
        listing = json.dumps({'devices': {'runtime': [{'udid': UDID, 'state': 'Shutdown'}]}})
        def run(command, **kwargs):
            events.append(command[2])
            return mock.Mock(stdout=listing)
        with mock.patch.object(simulator_settle.subprocess, 'run', side_effect=run), \
                mock.patch.object(background, 'prepare', side_effect=lambda _: events.append('prepare')), \
                mock.patch.object(background, 'verify', side_effect=lambda _: events.append('verify')):
            simulator_settle.boot(UDID, reduce_background=True)
        self.assertEqual(events, ['list', 'prepare', 'boot', 'bootstatus', 'verify'])

    def test_profile_refuses_an_already_booted_simulator(self):
        listing = json.dumps({'devices': {'runtime': [{'udid': UDID, 'state': 'Booted'}]}})
        with mock.patch.object(simulator_settle.subprocess, 'run', return_value=mock.Mock(stdout=listing)), \
                mock.patch.object(background, 'prepare') as prepare:
            with self.assertRaises(RuntimeError):
                simulator_settle.boot(UDID, reduce_background=True)
        prepare.assert_not_called()


if __name__ == '__main__':
    unittest.main()
