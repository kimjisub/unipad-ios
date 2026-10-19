"""Offline regression checks for the virtual MIDI verdict (no device needed)."""
import unittest
import argparse
from pathlib import Path
import sys
import tempfile
from virtual_launchpad_roundtrip import assess, Run, snapshot


class RoundTripVerdictTests(unittest.TestCase):
    def evidence(self):
        # Unified-log times and mach times are separate clocks; TX/RX share mach time.
        log = ('user_property platform=ios\n'
               'MIDI IN: cmd=9 sig=-112 note=81 vel=127\n'
               'MIDI IN: cmd=9 sig=-112 note=81 vel=0\n'
               'MIDI IN: cmd=9 sig=-112 note=82 vel=127\n'
               'MIDI IN: cmd=9 sig=-112 note=82 vel=0\n'
               'event play_first_input input_source=midi play_session_id=one\n')
        return log, '1.0 90 51 7F\n1.2 90 51 00\n2.0 90 52 7F\n2.2 90 52 00\n', '1.1 90 51 05\n2.1 90 52 09\n'

    def test_accepts_both_input_orders(self):
        log, sent, received = self.evidence()
        assess(log, sent, received, 'midi')
        assess(log.replace('input_source=midi', 'input_source=screen'), sent, received, 'screen')

    def test_rejects_duplicate_or_wrong_first_input(self):
        log, sent, received = self.evidence()
        for invalid in [log + log, log.replace('input_source=midi', 'input_source=screen')]:
            with self.assertRaises(ValueError):
                assess(invalid, sent, received, 'midi')

    def test_rejects_send_only_missing_release_or_missing_app_input(self):
        log, sent, received = self.evidence()
        for invalid in [log.replace('note=82 vel=127', 'note=83 vel=127'),
                        log.replace('note=81 vel=0', 'note=83 vel=0')]:
            with self.assertRaises(ValueError):
                assess(invalid, sent, received, 'midi')
        with self.assertRaises(ValueError):
            assess(log, sent.splitlines()[0], received, 'midi')

    def test_rejects_zero_unrelated_and_earlier_lights(self):
        log, sent, _ = self.evidence()
        for invalid in ['0.5 90 51 05\n0.6 90 52 09\n',
                        '1.1 90 51 00\n2.1 90 52 00\n',
                        '1.1 90 53 05\n2.1 90 54 09\n',
                        '1.1 90 51 05\n1.2 90 52 09\n']:
            with self.assertRaises(ValueError):
                assess(log, sent, invalid, 'midi')

    def test_requires_local_only_analytics(self):
        log, sent, received = self.evidence()
        with self.assertRaises(ValueError):
            assess(log.replace('user_property platform=ios', ''), sent, received, 'midi')

    def test_rejects_reordered_app_input(self):
        log, sent, received = self.evidence()
        with self.assertRaises(ValueError):
            assess(log.replace('note=81 vel=0', 'note=82 vel=0'), sent, received, 'midi')


class SafetyTests(unittest.TestCase):
    def test_timeout_names_the_wait_and_cleanup_reaps_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Run(argparse.Namespace(output=Path(temporary) / 'result', timeout=30))
            child = run.start([sys.executable, '-c', 'import time; time.sleep(60)'], 'child.log')
            try:
                with self.assertRaisesRegex(TimeoutError, 'waiting for readiness'):
                    run.wait(lambda: False, 0.1, 'readiness')
            finally:
                run.cleanup()
            self.assertIsNotNone(child.poll())

    def test_snapshot_detects_pack_and_setting_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            library = root / 'Documents/UniPack'
            library.mkdir(parents=True)
            before = snapshot(root)
            (library / 'unexpected').mkdir()
            self.assertNotEqual(before, snapshot(root))
            (library / 'unexpected').rmdir()
            prefs = root / 'Library/Preferences/kim.jisub.unipad.plist'
            prefs.parent.mkdir(parents=True)
            prefs.write_bytes(b'changed')
            self.assertNotEqual(before, snapshot(root))
