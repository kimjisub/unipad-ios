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

    def test_verifies_disabled_flags_and_that_neither_service_is_loaded(self):
        disabled = 'disabled services = {\n "com.apple.PosterBoard" => true\n "com.apple.chronod" => true\n}'
        with mock.patch.object(background.subprocess, 'run', side_effect=[
            mock.Mock(stdout=disabled, returncode=0),
            mock.Mock(stdout='', returncode=113), mock.Mock(stdout='', returncode=113),
        ]) as run:
            background.verify(UDID)
        self.assertEqual(run.call_args_list[0].args[0],
                         ['xcrun', 'simctl', 'spawn', UDID, 'launchctl', 'print-disabled', 'system'])
        self.assertEqual([c.args[0][-1] for c in run.call_args_list[1:]],
                         ['system/com.apple.PosterBoard', 'system/com.apple.chronod'])

    def test_missing_flag_or_loaded_service_fails_verification(self):
        for disabled, status in [
            ('"com.apple.PosterBoard" => false', 113),
            ('"com.apple.PosterBoard" => true\n"com.apple.chronod" => true', 0),
        ]:
            with self.subTest(disabled=disabled, status=status), mock.patch.object(
                background.subprocess, 'run', side_effect=[
                    mock.Mock(stdout=disabled, returncode=0),
                    mock.Mock(stdout='loaded service', returncode=status),
                ]):
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
