"""Offline regression checks for the virtual MIDI verdict (no device needed)."""
import unittest
from unittest.mock import patch, Mock
import argparse
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from virtual_launchpad_roundtrip import assess, assess_pro_initialization, main, Run, snapshot, scoped_log


class ProInitializationTests(unittest.TestCase):
    modes = ('0.0 F0 00 20 29 02 10 21 00 F7\n'
             '0.05 F0 00 20 29 02 10 22 00 F7\n'
             '0.1 F0 00 20 29 02 10 21 00 F7\n'
             '0.15 F0 00 20 29 02 10 22 00 F7\n')

    def test_accepts_lights_after_all_modes_and_settling(self):
        assess_pro_initialization(self.modes + '0.8 90 51 00\n')

    def test_a_later_redraw_cannot_hide_lights_sent_between_modes(self):
        received = self.modes.replace('0.05 F0', '0.01 90 51 05\n0.05 F0') + '1.0 90 51 05\n'
        with self.assertRaises(ValueError):
            assess_pro_initialization(received)

    def test_rejects_missing_mode_or_missing_settling_delay(self):
        with self.assertRaises(ValueError):
            assess_pro_initialization(self.modes + '0.64 90 51 00\n')
        with self.assertRaises(ValueError):
            assess_pro_initialization('0.0 F0 00 20 29 02 10 21 00 F7\n0.8 90 51 00\n')


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

    def test_accepts_multiple_messages_in_one_arrival_packet(self):
        log, sent, _ = self.evidence()
        assess(log, sent, '1.1 B0 68 00 90 51 05 52 00\n2.1 90 52 09 51 00\n', 'midi')

    def test_ignores_another_app_process_but_rejects_a_restarted_test_app(self):
        log, sent, received = self.evidence()
        own = '\n'.join(f'unipad[123:abc] [test.bundle:AnalyticsLocal] {line}' for line in log.splitlines())
        other = own.replace('123:', '456:').replace('test.bundle:', 'other.bundle:')
        scoped, pid = scoped_log(own + '\n' + other, 'test.bundle')
        self.assertEqual(pid, 123)
        assess(scoped, sent, received, 'midi')
        with self.assertRaises(ValueError):
            scoped_log(own + '\n' + own.replace('123:', '789:'), 'test.bundle')

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
    def test_preserves_existing_installations_before_a_build_failure(self):
        app = 'io.unipad.tests.virtual-midi'
        for existing in [{app}, {app + '.xctrunner'}, {app, app + '.xctrunner'}, set()]:
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as temporary:
                run = Run(argparse.Namespace(output=Path(temporary) / 'result', timeout=30,
                                             simulator='test-device', derived_data=Path(temporary) / 'dd'))
                installed = set(existing)

                def container(bundle, required=True):
                    return '/existing/' + bundle if bundle in installed else None

                def external(command, **kwargs):
                    if 'uninstall' in command:
                        installed.discard(command[-1])
                    return Mock(returncode=0)

                with patch.object(run, 'container', side_effect=container), \
                        patch.object(run, 'command', side_effect=RuntimeError('build failed')) as build, \
                        patch('virtual_launchpad_roundtrip.subprocess.run', side_effect=external) as commands, \
                        patch('virtual_launchpad_roundtrip.subprocess.check_output', return_value='test-commit'):
                    with self.assertRaises(RuntimeError) as failure:
                        run.execute()
                    run.cleanup()
                self.assertEqual(installed, existing)
                self.assertFalse(any('uninstall' in call.args[0] for call in commands.call_args_list))
                self.assertEqual(build.call_count, 0 if existing else 1)
                self.assertIn('already installed' if existing else 'build failed', str(failure.exception))

    def test_failed_install_removes_only_the_app_it_left_installed(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Run(argparse.Namespace(output=Path(temporary) / 'result', timeout=30,
                                         simulator='test-device', derived_data=Path(temporary) / 'dd'))
            installed = set()

            def command(command, name, seconds=180):
                if name == 'install.log':
                    installed.add(run.bundle)
                    raise RuntimeError('install failed after copying the app')

            def external(command, **kwargs):
                if 'uninstall' in command:
                    installed.remove(command[-1])
                return Mock(returncode=0)

            with patch.object(run, 'container', side_effect=lambda bundle, required=True:
                              '/installed/' + bundle if bundle in installed else None), \
                    patch.object(run, 'command', side_effect=command), \
                    patch('virtual_launchpad_roundtrip.subprocess.run', side_effect=external) as commands, \
                    patch('virtual_launchpad_roundtrip.subprocess.check_output', return_value='test-commit'):
                with self.assertRaisesRegex(RuntimeError, 'install failed'):
                    run.execute()
                run.cleanup()
            self.assertEqual(installed, set())
            removed = [call.args[0][-1] for call in commands.call_args_list if 'uninstall' in call.args[0]]
            self.assertEqual(removed, [run.bundle])
            self.assertTrue(run.report['test_app_removed'])

    def test_cleanup_removes_the_test_app_when_stopping_a_process_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Run(argparse.Namespace(output=Path(temporary) / 'result', timeout=30,
                                         simulator='test-device', derived_data=Path(temporary) / 'dd'))
            installed = {run.bundle, run.bundle + '.xctrunner'}
            run.install_attempts = set(installed)

            def external(command, **kwargs):
                if 'uninstall' in command:
                    installed.discard(command[-1])
                return Mock(returncode=0)

            with patch.object(run, 'container', side_effect=lambda bundle, required=True:
                              '/installed/' + bundle if bundle in installed else None), \
                    patch.object(run, 'stop_device', side_effect=RuntimeError('device did not stop')), \
                    patch('virtual_launchpad_roundtrip.subprocess.run', side_effect=external):
                with self.assertRaisesRegex(RuntimeError, 'device did not stop'):
                    run.cleanup()
            self.assertEqual(installed, set())
            self.assertTrue(run.report['test_app_removed'])

    def test_hang_up_stops_the_run_and_cleanup_ignores_further_stops(self):
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
                patch.object(sys, 'argv', ['roundtrip', '--simulator', 'test-device', '--output',
                                           str(Path(temporary) / 'result'), '--derived-data', temporary]), \
                patch.object(Run, 'execute', execute), patch.object(Run, 'cleanup', cleanup), \
                patch('builtins.print'):
            self.assertEqual(main(), 1)
        self.assertTrue(all(callable(handler) for handler in seen['run'].values()), seen['run'])
        self.assertEqual(set(seen['cleanup'].values()), {signal.SIG_IGN})

    def test_stop_queries_only_its_child_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Run(argparse.Namespace(output=Path(temporary) / 'result', timeout=30))
            child = Mock(pid=7101)
            child.poll.return_value = None
            replies = {'7101': '7102\n', '7102': '7103\n', '7103': ''}

            def query(command, **kwargs):
                self.assertEqual(command[:2], ['pgrep', '-P'])
                return Mock(returncode=0 if replies[command[2]] else 1,
                            stdout=replies[command[2]], stderr='')

            with patch('virtual_launchpad_roundtrip.subprocess.check_output',
                       side_effect=AssertionError('must not enumerate the whole Mac')), \
                    patch('virtual_launchpad_roundtrip.subprocess.run', side_effect=query) as queries, \
                    patch('virtual_launchpad_roundtrip.os.kill') as stop:
                run.stop(child)
            self.assertEqual({call.args[0][2] for call in queries.call_args_list}, set(replies))
            self.assertEqual({call.args[0] for call in stop.call_args_list}, {7102, 7103})
            child.terminate.assert_called_once()
            child.wait.assert_called_once_with(timeout=10)

    def test_failed_child_query_still_reaps_the_direct_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Run(argparse.Namespace(output=Path(temporary) / 'result', timeout=30))
            child = run.start([sys.executable, '-c', 'import time; time.sleep(60)'], 'child.log')
            try:
                with patch('virtual_launchpad_roundtrip.subprocess.check_output',
                           side_effect=subprocess.TimeoutExpired('ps', 10)), \
                        patch('virtual_launchpad_roundtrip.subprocess.run',
                              side_effect=subprocess.TimeoutExpired('pgrep', 10)):
                    with self.assertRaises(subprocess.TimeoutExpired):
                        run.stop(child)
                self.assertIsNotNone(child.poll())
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=10)
                for handle in run.handles:
                    handle.close()

    def test_cleanup_reaps_other_children_after_a_query_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = Run(argparse.Namespace(output=Path(temporary) / 'result', timeout=30))
            children = [run.start([sys.executable, '-c', 'import time; time.sleep(60)'],
                                  f'child-{index}.log') for index in range(2)]
            try:
                with patch('virtual_launchpad_roundtrip.subprocess.check_output',
                           side_effect=subprocess.TimeoutExpired('ps', 10)), \
                        patch('virtual_launchpad_roundtrip.subprocess.run',
                              side_effect=subprocess.TimeoutExpired('pgrep', 10)):
                    with self.assertRaises(subprocess.TimeoutExpired):
                        run.cleanup()
                self.assertTrue(all(child.poll() is not None for child in children))
            finally:
                for child in children:
                    if child.poll() is None:
                        child.terminate()
                        child.wait(timeout=10)
                for handle in run.handles:
                    handle.close()

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
