import unittest
from unittest.mock import Mock, patch
import argparse
from pathlib import Path
import signal
import sys
import tempfile

from matrix_roundtrip import MatrixRun, main, release_error, uncleared_round_lights


class MatrixEvidenceTests(unittest.TestCase):
    sent = '10.0 90 40 7F\n11.0 90 40 00\n'
    stopped = '10.1 91 40 05\n11.1 91 40 00\n'

    def test_a_release_with_a_full_observation_is_accepted(self):
        self.assertIsNone(release_error(self.sent, self.stopped, 12.1))

    def test_a_send_without_returning_lights_is_rejected(self):
        self.assertIn('never returned', release_error(self.sent, '', 12.1))

    def test_continuing_endless_lights_are_rejected_even_if_exit_clears_them(self):
        received = self.stopped + '11.5 91 40 05\n11.6 91 40 00\n13.0 91 40 00\n'
        self.assertIn('continued', release_error(self.sent, received, 12.1))

    def test_a_later_exit_clear_cannot_prove_release(self):
        self.assertIn('did not return', release_error(self.sent, '10.1 91 40 05\n', 12.1))

    def test_missing_or_repeated_input_is_rejected(self):
        self.assertIn('missing ordered', release_error(self.sent * 2, self.stopped, 12.1))
        self.assertIn('incomplete', release_error(self.sent, self.stopped, 11.9))

    def test_entry_clear_cannot_hide_an_omitted_exit_clear(self):
        notes = list(range(28, 36)) + list(range(100, 124))
        entry = ''.join(f'10.0 91 {n:02X} 00\n' for n in notes)
        exit_clear = ''.join(f'21.0 91 {n:02X} 00\n' for n in notes if n != 108)
        self.assertEqual(uncleared_round_lights(entry + exit_clear, 20), [108])

    def test_homes_later_navigation_lights_do_not_invalidate_the_exit_clear(self):
        notes = list(range(28, 36)) + list(range(100, 124))
        exit_clear = ''.join(f'21.0 91 {n:02X} 00\n' for n in notes)
        self.assertEqual(uncleared_round_lights(exit_clear + '22.0 91 1C 05\n22.0 91 1D 05\n', 20), [])

    def test_an_already_stopped_shared_app_does_not_prevent_the_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = MatrixRun(argparse.Namespace(output=Path(temporary) / 'result', timeout=30,
                                              simulator='test-device', derived_data=Path(temporary) / 'dd'))
            stopped = Mock(returncode=3, stderr='The request failed: found nothing to terminate.')
            with patch.object(run, 'container', side_effect=lambda bundle, required=True:
                              '/shared-app' if bundle == 'kim.jisub.unipad' else None), \
                    patch('matrix_roundtrip.subprocess.check_output', return_value='test-commit'), \
                    patch('matrix_roundtrip.subprocess.run', return_value=stopped), \
                    patch('matrix_roundtrip.snapshot', return_value={}), \
                    patch.object(run, 'command', side_effect=RuntimeError('reached build')):
                with self.assertRaisesRegex(RuntimeError, 'reached build'):
                    run.execute()

    def test_hang_up_reaches_cleanup_and_further_stops_cannot_interrupt_it(self):
        stops = [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]
        for stop in stops:
            self.addCleanup(signal.signal, stop, signal.getsignal(stop))
        seen = {}

        def execute(run):
            seen['run'] = {stop: signal.getsignal(stop) for stop in stops}
            raise RuntimeError('stopped')

        def cleanup(run):
            seen['cleanup'] = {stop: signal.getsignal(stop) for stop in stops}

        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(sys, 'argv', ['matrix', '--simulator', 'test-device', '--output',
                                           str(Path(temporary) / 'result'), '--derived-data', temporary]), \
                patch.object(MatrixRun, 'execute', execute), patch.object(MatrixRun, 'cleanup', cleanup), \
                patch('builtins.print'):
            self.assertEqual(main(), 1)
        self.assertTrue(all(callable(handler) for handler in seen['run'].values()), seen['run'])
        self.assertEqual(set(seen['cleanup'].values()), {signal.SIG_IGN})


if __name__ == '__main__':
    unittest.main()
