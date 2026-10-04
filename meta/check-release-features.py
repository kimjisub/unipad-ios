"""Regression checks for process continuity and full-container restoration."""
import importlib.util
import os
from pathlib import Path
import tempfile
import sys
import json
import threading
import unittest
from unittest.mock import patch
import subprocess
import io
from contextlib import redirect_stdout

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('run-release-features.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class ReleaseRunnerTests(unittest.TestCase):
    def test_crash_reports_ignore_other_devices_and_timestamp_only_changes(self):
        with tempfile.TemporaryDirectory(dir=os.environ["PAPERCLIP_RUN_SCRATCH_DIR"]) as scratch:
            home = Path(scratch)
            reports = home / "Library/Logs/DiagnosticReports"
            reports.mkdir(parents=True)
            ours = reports / "unipad-existing.ips"
            ours.write_text("device: lent-device; existing report")
            (reports / "unipad-other.ips").write_text("device: another-worker")
            with patch.object(Path, "home", return_value=home):
                before = runner.crashes("lent-device")
                os.utime(ours, ns=(1, 1))
                self.assertEqual(before, runner.crashes("lent-device"))
                self.assertEqual(set(before), {str(ours)})
                fresh = reports / "unipad-new.ips"
                fresh.write_text("device: lent-device; new crash report")
                after = runner.crashes("lent-device")
                self.assertEqual(set(after) - set(before), {str(fresh)})
                ours.write_text("device: lent-device; changed report")
                self.assertNotEqual(before[str(ours)], runner.crashes("lent-device")[str(ours)])

    def test_restart_and_missing_process_are_rejected(self):
        runner.require_same_process(42, 42)
        for before, after in [(42, 43), (42, None), (None, None)]:
            with self.assertRaises(RuntimeError):
                runner.require_same_process(before, after)

    def test_ordinary_build_has_no_testing_only_options(self):
        options = runner.xcode_args(Path('source'), Path('build'), 'lent-device', testing=False)
        self.assertNotIn('-enableCodeCoverage', options)
        self.assertNotIn('-collect-test-diagnostics', options)
        self.assertNotIn('-parallel-testing-enabled', options)
        self.assertIn('platform=iOS Simulator,id=lent-device', options)

    def test_device_start_failure_still_returns_harness_lease(self):
        def output(argv, **kwargs):
            if argv[:2] == ['git', 'rev-parse']:
                return 'test-commit\n'
            if argv[:2] == ['git', 'diff']:
                return b''
            raise RuntimeError('device start failed after allocating a lease')
        with tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) as scratch, \
             patch.dict(os.environ, {'PAPERCLIP_RUN_SCRATCH_DIR': scratch}), \
             patch('sys.argv', ['run-release-features.py']), \
             patch.object(runner, 'stage_source', side_effect=lambda repo, target: target.mkdir()), \
             patch.object(runner.subprocess, 'check_output', side_effect=output), \
             patch.object(runner, 'command', return_value=subprocess.CompletedProcess([], 0)) as command, \
             redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):
                runner.main()
        self.assertEqual(command.call_args.args[1][-1], 'down')

    def test_termination_signal_restores_data_and_returns_device(self):
        # Send a real signal only to an isolated child, with device operations
        # replaced. A missing handler must never terminate this test process.
        program = r"""
import importlib.util, os, signal, subprocess, sys, json
from pathlib import Path
from unittest.mock import patch
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("runner", sys.argv[1])
runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
root = Path(os.environ["PAPERCLIP_RUN_SCRATCH_DIR"])
order = []
def output(argv, **kwargs):
    if argv[:2] == ["git", "diff"]: return b""
    return "fake-device-or-commit\n"
def command(record, argv, **kwargs):
    if argv[-1] == "down": order.append("down")
    return subprocess.CompletedProcess(argv, 0)
def stop(*args):
    os.kill(os.getpid(), signal.SIGTERM)
with patch.object(runner, "stage_source", side_effect=lambda repo, path: path.mkdir()), \
     patch.object(runner.subprocess, "check_output", side_effect=output), \
     patch.object(runner, "snapshot", return_value=None), \
     patch.object(runner, "restore", side_effect=lambda *args: order.append("restore")), \
     patch.object(runner, "target_checks", side_effect=stop), \
     patch.object(runner, "command", side_effect=command), \
     patch("sys.argv", ["runner", "--target-ref", "fake-target"]):
    try: runner.main()
    except RuntimeError: pass
assert order == ["restore", "down"], order
receipt = json.loads(next(root.glob("release-features-*/receipt.json")).read_text())
assert not receipt["success"] and "KeyboardInterrupt" in receipt["executionError"]
assert receipt["deviceDownExitCode"] == 0 and not receipt["cleanupErrors"]
"""
        with tempfile.TemporaryDirectory(dir=os.environ["PAPERCLIP_RUN_SCRATCH_DIR"]) as scratch:
            environment = dict(os.environ, PAPERCLIP_RUN_SCRATCH_DIR=scratch)
            result = subprocess.run([sys.executable, "-c", program, str(Path(runner.__file__).resolve())],
                                    env=environment, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_first_signals_during_restore_finish_hash_verification_and_device_return(self):
        # Exercise real main/restore/restore_tree in isolated children. Inject
        # the first signal after deletion and halfway through copying, for both
        # stop signals; repeated requests must also leave cleanup uninterrupted.
        self.run_restore_signal_checks()

    def test_failed_restore_keeps_verified_backup_outside_run_scratch(self):
        self.run_restore_signal_checks(fail_copy=True)

    def run_restore_signal_checks(self, fail_copy=False):
        program = r"""
import importlib.util, os, signal, subprocess, sys, json, shutil
from pathlib import Path
from unittest.mock import patch
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("runner", sys.argv[1])
runner = importlib.util.module_from_spec(spec); spec.loader.exec_module(runner)
root = Path(os.environ["PAPERCLIP_RUN_SCRATCH_DIR"])
# __file__ identifies an isolated checkout, not the real repository.
repo = root.parent / (root.name + "-checkout")
repo.mkdir(); (repo / "meta").mkdir()
(repo / "ReleaseFeatures.xctestplan").write_text('{}')
runner.__file__ = str(repo / 'meta/run-release-features.py')
original, app = root / 'data', root / 'app'
original.mkdir(); app.mkdir()
(original / 'history').write_bytes(b'original database')
(original / 'preferences').write_bytes(b'original settings')
(app / 'binary').write_bytes(b'original app')
expected = runner.tree_hashes(original)
order = []
def output(argv, **kwargs):
    if argv[:2] == ['git', 'diff']: return b''
    return 'fake-device-or-commit\n'
def command(record, argv, **kwargs):
    if argv[-1] == 'down':
        order.append('down')
    if 'listapps' in argv: return subprocess.CompletedProcess(argv, 0, 'app list')
    return subprocess.CompletedProcess(argv, 0)
def check(*args):
    (original / 'history').write_bytes(b'test data')
copytree = shutil.copytree
injected = False
def copy(source, destination, **kwargs):
    global injected
    if Path(destination) == original:
        assert not list(original.iterdir()), 'signal must follow deletion'
        injected = True
        if fail_copy: raise OSError('injected copy failure')
        if phase == 'during-copy':
            (original / 'history').write_bytes((Path(source) / 'history').read_bytes())
            assert not (original / 'preferences').exists()
        os.kill(os.getpid(), requested_signal)
        os.kill(os.getpid(), signal.SIGINT)
    return copytree(source, destination, **kwargs)
fail_copy, phase, requested_signal = sys.argv[2] == 'true', sys.argv[3], int(sys.argv[4])
with patch.object(runner, 'stage_source', side_effect=lambda repo, path: path.mkdir()), \
     patch.object(runner.subprocess, 'check_output', side_effect=output), \
     patch.object(runner.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '{"kim.jisub.unipad": {}}')), \
     patch.object(runner, 'container', side_effect=lambda record, device, kind, **kw: app if kind == 'app' else original), \
     patch.object(runner, 'target_checks', side_effect=check), \
     patch.object(runner, 'command', side_effect=command), \
     patch.object(runner.shutil, 'copytree', side_effect=copy), \
     patch('sys.argv', ['runner', '--target-ref', 'fake-target']):
    try: runner.main()
    except RuntimeError: pass
receipt = json.loads(next(root.glob('release-features-*/receipt.json')).read_text())
assert injected and order == ['down']
assert not receipt['success'] and receipt.get('deviceDownExitCode') == 0
if not fail_copy:
    assert runner.tree_hashes(original) == expected, ('restoration interrupted', runner.tree_hashes(original))
backup = Path(receipt['recoveryBackupPath'])
if fail_copy:
    assert receipt['cleanupErrors'] and receipt['recoveryBackupPreserved']
    assert not backup.is_relative_to(root)
    assert runner.tree_hashes(backup / 'data') == expected
    assert runner.tree_hashes(backup / 'unipad.app') == runner.tree_hashes(app)
    assert (backup / 'manifest.json').is_file()
    shutil.rmtree(root)  # Simulate runtime removing run-owned scratch.
    assert runner.tree_hashes(backup / 'data') == expected
else:
    assert receipt['appRestored'] and receipt['dataRestored']
    assert runner.tree_hashes(original) == expected
    assert receipt['terminationRequests'] and not receipt['cleanupErrors']
    assert not backup.exists() and not receipt['recoveryBackupPreserved']
shutil.rmtree(repo)
"""
        import signal
        for phase in ['after-deletion', 'during-copy']:
            for requested_signal in [signal.SIGTERM, signal.SIGINT]:
                with self.subTest(phase=phase, signal=requested_signal), \
                     tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) as scratch:
                    result = subprocess.run([sys.executable, '-c', program, str(Path(runner.__file__).resolve()),
                                             str(fail_copy).lower(), phase, str(int(requested_signal))],
                                            env=dict(os.environ, PAPERCLIP_RUN_SCRATCH_DIR=scratch),
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_overlapping_commands_cannot_share_device_lease(self):
        with tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) as scratch, \
             patch.dict(os.environ, {'PAPERCLIP_RUN_SCRATCH_DIR': scratch}):
            with runner.run_lock():
                with self.assertRaises(RuntimeError):
                    with runner.run_lock():
                        self.fail('overlapping command must not acquire the lease')
            with runner.run_lock():
                pass  # Restoration finished; the next command may proceed.

    def test_reader_never_observes_a_partial_acknowledgement(self):
        with tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) as scratch:
            root = Path(scratch)
            partial, checked = threading.Event(), threading.Event()
            errors = []
            def reader():
                try:
                    self.assertTrue(partial.wait(5))
                    final = root / 'point.ack'
                    if final.exists():
                        json.loads(final.read_text())
                except BaseException as error:
                    errors.append(error)
                finally:
                    checked.set()
            def write_in_chunks(path, data, *args, **kwargs):
                with path.open('w') as output:
                    output.write(data[:1])
                    output.flush()
                    partial.set()
                    self.assertTrue(checked.wait(5))
                    output.write(data[1:])
                return len(data)
            thread = threading.Thread(target=reader)
            thread.start()
            with patch.object(Path, 'write_text', write_in_chunks):
                runner.acknowledge(root, 'point', {'error': 'complete response'})
            thread.join(5)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])
            self.assertEqual(json.loads((root / 'point.ack').read_text()), {'error': 'complete response'})

    def test_process_lookup_requires_exact_app_service(self):
        self.assertEqual(runner.app_pid('12 0 UIKitApplication:kim.jisub.unipad[abc]\n99 0 UIKitApplication:kim.jisub.unipadUITests.xctrunner[xyz]'), 12)
        self.assertIsNone(runner.app_pid('- 0 UIKitApplication:kim.jisub.unipad[abc]'))

    def test_restore_preserves_database_preferences_and_pack_bytes(self):
        with tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) as tmp:
            root = Path(tmp)
            original, backup = root / 'original', root / 'backup'
            for name in ['Documents/UniPack/Pack/info', 'Library/Application Support/default.store',
                         'Library/Application Support/default.store-wal', 'Library/Preferences/app.plist']:
                path = original / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(name.encode())
            before = runner.tree_hashes(original)
            runner.copy_verified(original, backup)
            (original / 'Library/Application Support/default.store').write_bytes(b'changed by test')
            (original / 'Documents/new-fixture').write_bytes(b'test only')
            runner.restore_tree(backup, original)
            self.assertEqual(runner.tree_hashes(original), before)

    def test_changed_backup_never_erases_current_data(self):
        with tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) as tmp:
            root = Path(tmp)
            original, backup = root / 'original', root / 'backup'
            original.mkdir()
            (original / 'history').write_bytes(b'keep')
            expected = runner.copy_verified(original, backup)
            (backup / 'history').write_bytes(b'corrupt')
            with self.assertRaises(RuntimeError):
                runner.restore_tree(backup, original, expected)
            self.assertEqual((original / 'history').read_bytes(), b'keep')

    def test_overlapping_restore_paths_preserve_data(self):
        with tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) as tmp:
            root = Path(tmp)
            (root / 'history').write_bytes(b'keep')
            with self.assertRaises(RuntimeError):
                runner.restore_tree(root, root)
            with self.assertRaises(RuntimeError):
                runner.copy_verified(root, root / 'backup')
            self.assertEqual((root / 'history').read_bytes(), b'keep')

    def test_clean_target_keeps_simulator_container_identity(self):
        with tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) as tmp:
            data = Path(tmp)
            identity = data / '.com.apple.mobile_container_manager.metadata.plist'
            identity.write_bytes(b'container identity')
            (data / 'Documents').mkdir()
            (data / 'Documents/old-pack').write_bytes(b'old test data')
            runner.reset_target_data(data)
            self.assertEqual(identity.read_bytes(), b'container identity')
            self.assertFalse((data / 'Documents').exists())

    def test_unverified_backup_never_erases_existing_data(self):
        with tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) as tmp:
            root = Path(tmp)
            original = root / 'original'
            original.mkdir()
            (original / 'history').write_bytes(b'keep')
            with self.assertRaises(RuntimeError):
                runner.restore_tree(root / 'missing', original)
            self.assertEqual((original / 'history').read_bytes(), b'keep')


if __name__ == '__main__':
    unittest.main()
