"""Failure-path regressions; fake device commands, run-owned temporary files only."""
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR'])
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        (self.source / 'unipad').mkdir(parents=True)
        (self.source / 'unipad/product.swift').write_bytes(b'baseline')
        (self.source / 'unipadUITests').mkdir()
        self.build = self.root / 'build'
        products = self.build / 'Build/Products/Debug-iphonesimulator'
        (products / 'unipad.app').mkdir(parents=True)
        (products / 'unipad.app/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': 'test', 'CFBundleVersion': 'test'}))
        (products / 'unipadUITests-Runner.app').mkdir()
        self.container = self.root / 'container'
        self.library = self.container / 'Documents/UniPack'
        self.library.mkdir(parents=True)
        (self.library / 'existing').write_bytes(b'preserve me')
        self.staged = self.library / 'JIS-70-regression'
        self.pack = self.root / 'pack.zip'
        with zipfile.ZipFile(self.pack, 'w') as z:
            z.writestr('info', 'title=Conformance\n')
        self.out = self.root / 'out'
        self.commands = []
        self.recording_mode = 'ok'
        self.fail_command = None
        self.baseline_files = {
            'unipad/product.swift': b'baseline',
            'BundledThemes.bundle/sskin/colors.json': b'{"baseline": true}',
            'unipad.xcodeproj/project.pbxproj': b'baseline project',
            'unipadUITests/PlayPadLayoutTests.swift': b'baseline UI test',
        }
        for name, content in self.baseline_files.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        self.mock_product_files = list(self.baseline_files)

    def git(self, command, **kwargs):
        if command[1] == 'ls-tree':
            # Match git's path-limited enumeration from the tool subdirectory.
            return (('\0' if '-z' in command else '\n').join(self.mock_product_files).encode()
                    if '--full-tree' in command else b'')
        return self.baseline_files[command[2].split(':', 1)[1]]

    def invoke(self, command, log=None, check=True, timeout=None):
        self.commands.append(command)
        if log:
            log.write_text('fake command: ' + repr(command))
        if self.fail_command and self.fail_command(command):
            raise RuntimeError('injected command failure')
        output = str(self.container) if 'get_app_container' in command else ''
        return subprocess.CompletedProcess(command, 0, output, '')

    def popen(self, command, **kwargs):
        owner = self

        class Video:
            returncode = None

            def poll(self):
                if owner.recording_mode == 'early-exit':
                    self.returncode = 1
                return self.returncode

            def send_signal(self, sig):
                pass

            def wait(self, timeout=None):
                if owner.recording_mode == 'timeout' and self.returncode is None:
                    raise subprocess.TimeoutExpired(command, timeout)
                self.returncode = 1 if owner.recording_mode == 'early-exit' else (self.returncode or 0)
                if owner.recording_mode == 'ok':
                    Path(command[-1]).write_bytes(b'fake video')
                elif owner.recording_mode == 'empty':
                    Path(command[-1]).touch()
                return self.returncode

            def kill(self):
                self.returncode = -9

        return Video()

    def run_tool(self):
        argv = ['run.py', '--udid', 'fake-device', '--source', str(self.source),
                '--derived-data', str(self.build), '--pack', str(self.pack), '--out', str(self.out)]
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(sys, 'argv', argv))
            stack.enter_context(patch.dict(os.environ, PAPERCLIP_RUN_SCRATCH_DIR=str(self.root),
                                          PAPERCLIP_RUN_ID='regression', HARNESS=str(self.root)))
            stack.enter_context(patch.object(runner, 'AP001_SHA256', hashlib.sha256(self.pack.read_bytes()).hexdigest()
                                            if self.pack.exists() else 'missing'))
            stack.enter_context(patch.object(runner, 'invoke', self.invoke))
            stack.enter_context(patch.object(runner.subprocess, 'check_output', self.git))
            stack.enter_context(patch.object(runner.subprocess, 'Popen', self.popen))
            stack.enter_context(patch.object(runner.time, 'sleep'))
            runner.main()

    def receipt(self):
        return json.loads((self.out / 'receipt.json').read_text())

    def assert_returned(self):
        self.assertTrue(any(c[-1] == 'down' for c in self.commands), 'Device must be returned')

    def assert_cleaned(self):
        self.assert_returned()
        self.assertFalse(self.staged.exists(), 'Only our created fixture must be removed')
        self.assertEqual((self.library / 'existing').read_bytes(), b'preserve me')
        self.assertTrue((self.out / 'receipt.json').exists(), 'Failure receipt must be saved')

    def assert_failed(self):
        self.assertFalse(self.receipt()['success'])

    def test_changed_product_rejected_before_build(self):
        (self.source / 'unipad/product.swift').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'Product baseline differs'):
            self.run_tool()
        self.assertFalse(any(c[0] == 'xcodebuild' for c in self.commands))
        self.assert_returned()
        self.assertTrue((self.out / 'receipt.json').exists())
        self.assert_failed()

    def assert_rejected_before_build(self):
        with self.assertRaisesRegex(RuntimeError, 'Product baseline differs'):
            self.run_tool()
        self.assertFalse(any(c[0] == 'xcodebuild' for c in self.commands))
        self.assert_returned()
        self.assert_failed()

    def add_xcode_generated_files(self):
        names = [
            'unipad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
            'unipad.xcodeproj/project.xcworkspace/contents.xcworkspacedata',
            'unipad.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist',
        ]
        for name in names:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'Xcode generated')
        return names

    def test_xcode_generated_files_allowed_after_baseline_build(self):
        self.add_xcode_generated_files()
        self.run_tool()
        self.assertTrue(self.receipt()['success'])
        self.assertEqual(self.receipt()['unchangedProductFiles'], len(self.baseline_files))

    def test_xcode_generated_files_allowed_with_exact_overlay_for_rerun(self):
        self.add_xcode_generated_files()
        (self.source / 'unipadUITests/PlayPadLayoutTests.swift').write_bytes(
            (runner.TOOLS / 'PlayPadLayoutTests.swift').read_bytes())
        self.run_tool()
        self.assertTrue(self.receipt()['success'])

    def test_xcode_generated_files_do_not_allow_changed_product(self):
        self.add_xcode_generated_files()
        (self.source / 'unipad/product.swift').write_bytes(b'changed')
        self.assert_rejected_before_build()

    def test_source_next_to_xcode_generated_files_rejected(self):
        names = self.add_xcode_generated_files()
        (self.source / names[0]).with_name('QAExtra.swift').write_bytes(b'added source')
        self.assert_rejected_before_build()

    def test_xcode_generated_symlink_rejected(self):
        name = self.add_xcode_generated_files()[0]
        path = self.source / name
        path.unlink()
        path.symlink_to(self.source / 'unipad/product.swift')
        self.assert_rejected_before_build()

    def test_tracked_xcode_generated_file_still_compared(self):
        name = self.add_xcode_generated_files()[0]
        self.baseline_files[name] = b'tracked original'
        self.mock_product_files.append(name)
        self.assert_rejected_before_build()

    def test_added_product_rejected_before_build(self):
        (self.source / 'unipad/QAExtra.swift').write_bytes(b'added product')
        self.assert_rejected_before_build()

    def test_missing_product_rejected_before_build(self):
        (self.source / 'unipad/product.swift').unlink()
        self.assert_rejected_before_build()

    def test_changed_theme_rejected_before_build(self):
        (self.source / 'BundledThemes.bundle/sskin/colors.json').write_bytes(b'changed')
        self.assert_rejected_before_build()

    def test_added_theme_rejected_before_build(self):
        (self.source / 'BundledThemes.bundle/sskin/extra.json').write_bytes(b'added')
        self.assert_rejected_before_build()

    def test_missing_theme_rejected_before_build(self):
        (self.source / 'BundledThemes.bundle/sskin/colors.json').unlink()
        self.assert_rejected_before_build()

    def test_changed_project_rejected_before_build(self):
        (self.source / 'unipad.xcodeproj/project.pbxproj').write_bytes(b'changed')
        self.assert_rejected_before_build()

    def test_changed_ui_overlay_rejected_before_build(self):
        (self.source / 'unipadUITests/PlayPadLayoutTests.swift').write_bytes(b'unknown overlay')
        self.assert_rejected_before_build()

    def test_exact_ui_overlay_allowed_for_rerun(self):
        (self.source / 'unipadUITests/PlayPadLayoutTests.swift').write_bytes(
            (runner.TOOLS / 'PlayPadLayoutTests.swift').read_bytes())
        self.run_tool()
        self.assertTrue(self.receipt()['success'])

    def test_product_symlink_rejected_before_build(self):
        target = self.root / 'outside.swift'
        target.write_bytes(b'baseline')
        product = self.source / 'unipad/product.swift'
        product.unlink()
        product.symlink_to(target)
        self.assert_rejected_before_build()

    def test_empty_product_list_rejected(self):
        self.mock_product_files = []
        with self.assertRaisesRegex(RuntimeError, 'empty'):
            self.run_tool()
        self.assert_returned()

    def test_collision_preserves_existing_folder(self):
        self.staged.mkdir()
        old_file = self.staged / 'valuable'
        old_file.write_bytes(b'keep')
        with self.assertRaises(Exception):
            self.run_tool()
        self.assertTrue(old_file.exists(), 'Never delete a fixture folder we did not create')
        self.assertEqual(old_file.read_bytes(), b'keep')
        self.assert_returned()
        self.assertTrue((self.out / 'receipt.json').exists())
        self.assert_failed()

    def test_missing_pack_returns_device_and_saves_failure(self):
        self.pack.unlink()
        with self.assertRaises(Exception):
            self.run_tool()
        self.assert_returned()
        self.assertTrue((self.out / 'receipt.json').exists())
        self.assert_failed()

    def test_recording_timeout_still_cleans_and_records_failure(self):
        self.recording_mode = 'timeout'
        with self.assertRaises(Exception):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()
        self.assertEqual(self.receipt()['cleanupErrors'][0]['step'], 'recording')

    def test_recording_early_failure_rejected(self):
        self.recording_mode = 'early-exit'
        with self.assertRaisesRegex(RuntimeError, 'recording'):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()

    def test_missing_video_rejected(self):
        self.recording_mode = 'missing'
        with self.assertRaisesRegex(RuntimeError, 'recording'):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()

    def test_empty_video_rejected(self):
        self.recording_mode = 'empty'
        with self.assertRaisesRegex(RuntimeError, 'recording'):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()

    def test_container_failure_does_not_skip_device_return_or_receipt(self):
        calls = 0

        def fail(command):
            nonlocal calls
            if 'get_app_container' in command:
                calls += 1
                return calls == 2
            return False

        self.fail_command = fail
        with self.assertRaises(Exception):
            self.run_tool()
        self.assert_returned()
        self.assertTrue((self.out / 'receipt.json').exists())
        # Without a confirmed current container, preserve rather than guess.
        self.assertTrue(self.staged.exists())
        self.assert_failed()

    def test_ui_command_failure_still_cleans(self):
        self.fail_command = lambda c: 'test-without-building' in c
        with self.assertRaises(Exception):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()

    def test_device_return_failure_is_recorded(self):
        self.fail_command = lambda c: c[-1] == 'down'
        with self.assertRaisesRegex(RuntimeError, 'device return'):
            self.run_tool()
        self.assertFalse(self.staged.exists())
        self.assert_failed()
        self.assertEqual(self.receipt()['cleanupErrors'][0]['step'], 'device return')

    def test_recorder_launch_failure_still_cleans(self):
        with patch.object(self, 'popen', side_effect=OSError('recording unavailable')):
            with self.assertRaisesRegex(RuntimeError, 'recording unavailable'):
                self.run_tool()
        self.assert_cleaned()
        self.assert_failed()

    def test_fixture_extraction_failure_still_cleans(self):
        with patch.object(zipfile.ZipFile, 'extractall', side_effect=OSError('extraction failed')):
            with self.assertRaisesRegex(RuntimeError, 'extraction failed'):
                self.run_tool()
        self.assert_cleaned()
        self.assert_failed()

    def test_success_counts_product_files_and_preserves_library(self):
        self.run_tool()
        self.assert_cleaned()
        self.assertEqual(self.receipt()['unchangedProductFiles'], len(self.baseline_files))
        self.assertTrue(self.receipt()['libraryRestored'])
        self.assertTrue(self.receipt()['success'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
