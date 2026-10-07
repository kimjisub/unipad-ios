"""Failure-path regressions; fake device commands, run-owned temporary files only."""
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.dont_write_bytecode = True
runner_path = Path(__file__).with_name('run.py')
if '--runner' in sys.argv:
    index = sys.argv.index('--runner')
    runner_path = Path(sys.argv[index + 1])
    del sys.argv[index:index + 2]
spec = importlib.util.spec_from_file_location('runner', runner_path)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def box(kind, body):
    return struct.pack('>I4s', 8 + len(body), kind) + body


def movie(seconds=38, version=0):
    """A minimal finalized movie: ftyp, moov/mvhd and mdat to the end of file."""
    if version == 1:
        mvhd = bytes([1, 0, 0, 0]) + bytes(16) + struct.pack('>IQ', 600, 600 * seconds)
    else:
        mvhd = bytes(4) + bytes(8) + struct.pack('>II', 600, 600 * seconds)
    return box(b'ftyp', b'qt  ') + box(b'moov', box(b'mvhd', mvhd + bytes(80))) + box(b'mdat', b'frames' * 10)


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
        self.xctestrun = self.build / 'Build/Products/unipad_unipad_iphonesimulator27.0-arm64.xctestrun'
        self.xctestrun.write_bytes(plistlib.dumps({'__xctestrun_metadata__': {'FormatVersion': 2}, 'TestConfigurations': [{
            'Name': 'Test Scheme Action', 'TestTargets': [
                {'BlueprintName': 'unipadTests', 'PreferredScreenCaptureFormat': 'screenRecording'},
                {'BlueprintName': 'unipadUITests', 'PreferredScreenCaptureFormat': 'screenRecording'}]}]}))
        os.utime(self.xctestrun, (0, 0))
        self.built_xctestruns = [self.xctestrun]
        self.container = self.root / 'container'
        self.library = self.container / 'Documents/UniPack'
        self.library.mkdir(parents=True)
        (self.library / 'existing').write_bytes(b'preserve me')
        self.staged = self.library / 'Conformance-regression'
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

    def invoke(self, command, log=None, check=True, timeout=None):
        self.commands.append(command)
        if log:
            log.write_text('fake command: ' + repr(command))
        if self.fail_command and self.fail_command(command):
            raise RuntimeError('injected command failure')
        if 'build-for-testing' in command:
            for xctestrun in self.built_xctestruns:
                if xctestrun.exists():
                    os.utime(xctestrun)
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
                mode = owner.recording_mode
                video = Path(command[-1])
                if mode.startswith('hung') and self.returncode is None:
                    # simctl finalizes (or not) the file, then never exits.
                    video.write_bytes(movie() if mode == 'hung-finalized' else movie()[:-5])
                if mode == 'frozen' or (mode in ('timeout', 'hung-finalized', 'hung-cut-off')
                                        and self.returncode is None):
                    # 'frozen' ignores even SIGKILL, so every wait times out.
                    raise subprocess.TimeoutExpired(command, timeout)
                if mode in ('ok', 'version-1', 'cut-off', 'nonzero') and self.returncode is None:
                    data = movie(version=1 if mode == 'version-1' else 0)
                    video.write_bytes(data[:-5] if mode == 'cut-off' else data)
                elif mode == 'empty':
                    video.touch()
                if self.returncode is None:
                    self.returncode = 1 if mode in ('early-exit', 'nonzero') else 0
                return self.returncode

            def kill(self):
                self.returncode = -9

        return Video()

    def run_tool(self):
        argv = ['run.py', '--udid', 'fake-device', '--source', str(self.source),
                '--derived-data', str(self.build), '--pack', str(self.pack), '--out', str(self.out)] + getattr(self, 'extra_args', [])
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(sys, 'argv', argv))
            stack.enter_context(patch.dict(os.environ, PAPERCLIP_RUN_SCRATCH_DIR=str(self.root),
                                          PAPERCLIP_RUN_ID='regression', HARNESS=str(self.root)))
            stack.enter_context(patch.object(runner, 'approved_pack', lambda path: ('TEST', hashlib.sha256(path.read_bytes()).hexdigest())))
            stack.enter_context(patch.object(runner, 'load_baseline', lambda: {name: hashlib.sha256(self.baseline_files[name]).hexdigest() for name in self.mock_product_files}))
            stack.enter_context(patch.object(runner, 'invoke', self.invoke))
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

    def assert_title_rejected_before_staging(self, filename, content):
        folder = self.library / 'another-folder-name'
        folder.mkdir()
        (folder / filename).write_bytes(content)
        before = runner.hashes(self.library)
        with self.assertRaisesRegex(RuntimeError, 'Conformance|decode'):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()
        self.assertEqual(runner.hashes(self.library), before)
        self.assertTrue(self.receipt()['libraryRestored'])
        self.assertNotIn('stagedName', self.receipt())
        self.assertFalse(any('test-without-building' in c for c in self.commands))
        self.assertFalse(any('recordVideo' in c for c in self.commands))

    def assert_other_title_allowed(self, content):
        folder = self.library / 'another-folder-name'
        folder.mkdir()
        (folder / 'info').write_bytes(content)
        before = runner.hashes(self.library)
        self.run_tool()
        self.assert_cleaned()
        self.assertTrue(self.receipt()['success'])
        self.assertEqual(self.receipt()['existingConformanceCount'], 0)
        self.assertEqual(self.receipt()['stagedConformanceCount'], 1)
        self.assertEqual(runner.hashes(self.library), before)
        self.assertTrue(self.receipt()['libraryRestored'])
        self.assertTrue(any('test-without-building' in c for c in self.commands))

    def test_arbitrary_title_reaches_ui(self):
        with zipfile.ZipFile(self.pack, 'w') as archive:
            archive.writestr('info', 'title=Spaced Title\n')
        self.run_tool()
        self.assertTrue(self.receipt()['success'])
        self.assertEqual(self.receipt()['fixtureTitle'], 'Spaced Title')
        self.assertTrue(any('test-without-building' in c for c in self.commands))

    def test_empty_title_reaches_ui_using_staged_folder_label(self):
        with zipfile.ZipFile(self.pack, 'w') as archive:
            archive.writestr('info', 'buttonX=4\nbuttonY=3\n')
        self.run_tool()
        self.assertEqual(self.receipt()['fixtureTitle'], '')
        self.assertEqual(self.receipt()['selectionTitle'], '')
        self.assertTrue(self.receipt()['success'])

    def test_keep_device_skips_return_after_failure(self):
        self.extra_args = ['--keep-device']
        self.fail_command = lambda c: 'test-without-building' in c
        with self.assertRaisesRegex(RuntimeError, 'UI|command'):
            self.run_tool()
        self.assertFalse(any(c[-1] == 'down' for c in self.commands))
        self.assertFalse(self.staged.exists())
        self.assertTrue(self.receipt()['libraryRestored'])
        self.assertFalse(self.receipt()['deviceReturned'])

    def test_approved_sample_fingerprints_and_modified_pack(self):
        approved = json.loads((runner.TOOLS / 'pack-fingerprints.json').read_text())
        self.assertEqual(len(approved), 20)
        self.assertEqual(len(set(approved.values())), 20)
        with self.assertRaisesRegex(RuntimeError, 'unchanged ZIP'):
            runner.approved_pack(self.pack)

    def test_output_outside_scratch_is_fresh_and_allowed(self):
        with tempfile.TemporaryDirectory(dir=self.root.parent) as directory:
            self.out = Path(directory) / 'evidence'
            self.run_tool()
            self.assertTrue(self.receipt()['success'])
            with self.assertRaises(RuntimeError):
                self.run_tool()

    def test_runner_does_not_need_git(self):
        with patch.object(runner.subprocess, 'check_output', side_effect=AssertionError('git must not run')):
            self.assertEqual(len(runner.load_baseline()), 236)
            self.run_tool()
        self.assertTrue(self.receipt()['success'])

    def test_ui_parameters_match_fixture_and_no_autoplay(self):
        self.run_tool()
        copy = self.xctestrun.with_name(runner.SCREENSHOTS_XCTESTRUN)
        targets = plistlib.loads(copy.read_bytes())['TestConfigurations'][0]['TestTargets']
        for target in targets:
            self.assertEqual(target['EnvironmentVariables']['CONFORMANCE_TITLE'], 'Conformance')
            self.assertEqual(target['EnvironmentVariables']['CONFORMANCE_HAS_AUTOPLAY'], 'NO')

    def test_conformance_number_suffix_allowed(self):
        self.assert_other_title_allowed(b'title=Conformance 2\n')

    def test_conformance_letter_suffix_allowed(self):
        self.assert_other_title_allowed(b'title=ConformanceX\n')

    def test_overridden_conformance_title_allowed(self):
        self.assert_other_title_allowed(b'title=Conformance\ntitle=Other\n')

    def test_duplicate_title_in_differently_named_folder(self):
        self.assert_title_rejected_before_staging('info', b'title=Conformance\n')

    def test_duplicate_title_with_spaces(self):
        self.assert_title_rejected_before_staging('info', b'  title = Conformance  \n')

    def test_duplicate_title_after_leading_separator(self):
        self.assert_title_rejected_before_staging('info', b'=title=Conformance\n')

    def test_duplicate_title_after_multiple_leading_separators(self):
        self.assert_title_rejected_before_staging('info', b'==title=Conformance\n')

    def test_title_with_leading_value_separator_allowed(self):
        self.assert_other_title_allowed(b'title==Conformance\n')

    def test_empty_title_line_does_not_override_duplicate(self):
        self.assert_title_rejected_before_staging('info', b'title=Conformance\ntitle=\n')

    def test_duplicate_title_in_uppercase_info(self):
        self.assert_title_rejected_before_staging('INFO', b'title=Conformance\n')

    def test_duplicate_title_in_json(self):
        self.assert_title_rejected_before_staging('info.json', b'{"title": "Conformance"}')

    def test_undecodable_info_preserved_and_device_returned(self):
        self.assert_title_rejected_before_staging('info', b'\xff')

    def test_duplicate_title_with_utf8_bom(self):
        self.assert_title_rejected_before_staging('info', '\ufefftitle = Conformance\n'.encode())

    def test_duplicate_title_with_utf16_bom(self):
        self.assert_title_rejected_before_staging('info', 'title=Conformance\n'.encode('utf-16'))

    def test_duplicate_title_with_legacy_encoding(self):
        self.assert_title_rejected_before_staging('info',
                                                'producerName=한글\ntitle = Conformance\n'.encode('cp949'))

    def test_unreadable_info_preserved_and_device_returned(self):
        path = self.library / 'another-folder-name/info'
        read_info = runner.read_info

        def unreadable(info):
            if info == path:
                raise RuntimeError('Cannot decode info: permission denied')
            return read_info(info)

        with patch.object(runner, 'read_info', side_effect=unreadable):
            self.assert_title_rejected_before_staging('info', b'title=Other pack\n')

    def test_info_title_uses_last_value_first_separator_and_json_fallback(self):
        folder = self.root / 'metadata'
        folder.mkdir()
        (folder / 'INFO.JSON').write_text('{"title": "Conformance"}')
        self.assertEqual(runner.folder_title(folder), 'Conformance')
        (folder / 'INFO').write_text('title = First\ntitle = Conformance=Other\ntitle=\n')
        self.assertEqual(runner.folder_title(folder), 'Conformance=Other')
        (folder / 'INFO').write_text('title = First\n  title = Conformance \n')
        self.assertEqual(runner.folder_title(folder), 'Conformance')

    def test_wrong_staged_title_stops_before_recording_and_ui(self):
        extractall = zipfile.ZipFile.extractall

        def wrong_title(archive, path):
            extractall(archive, path)
            (path / 'info').write_text('title=Other pack\n')

        with patch.object(zipfile.ZipFile, 'extractall', new=wrong_title):
            with self.assertRaisesRegex(RuntimeError, 'exactly one Conformance'):
                self.run_tool()
        self.assert_cleaned()
        self.assert_failed()
        self.assertTrue(self.receipt()['libraryRestored'])
        self.assertEqual(self.receipt()['stagedConformanceCount'], 0)
        self.assertFalse(any('test-without-building' in c for c in self.commands))
        self.assertFalse((self.out / 'walkthrough.mp4').exists())

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

    def test_recorder_frozen_through_kill_still_cleans_and_records_failure(self):
        self.recording_mode = 'frozen'
        with self.assertRaises(Exception):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()
        receipt = self.receipt()
        self.assertEqual(receipt['cleanupErrors'][0]['step'], 'recording')
        self.assertIn('TimeoutExpired', receipt['cleanupErrors'][0]['error'])

    def test_recording_early_failure_rejected(self):
        self.recording_mode = 'early-exit'
        with self.assertRaisesRegex(RuntimeError, 'recording'):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()

    def test_recorder_hung_after_finalized_movie_accepted(self):
        self.recording_mode = 'hung-finalized'
        self.run_tool()
        self.assert_cleaned()
        receipt = self.receipt()
        self.assertTrue(receipt['success'])
        self.assertTrue(receipt['recordingHungAfterStop'])
        self.assertEqual(receipt['recordingExitCode'], -9)
        self.assertEqual(receipt['recordingSeconds'], 38)

    def test_recorder_hung_with_cut_off_movie_rejected(self):
        self.recording_mode = 'hung-cut-off'
        with self.assertRaisesRegex(RuntimeError, 'recording'):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()
        self.assertIsNone(self.receipt()['recordingSeconds'])

    def test_cut_off_movie_rejected(self):
        self.recording_mode = 'cut-off'
        with self.assertRaisesRegex(RuntimeError, 'recording'):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()

    def test_finalized_movie_with_nonzero_exit_rejected(self):
        self.recording_mode = 'nonzero'
        with self.assertRaisesRegex(RuntimeError, 'recording'):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()

    def test_version_1_movie_header_read(self):
        self.recording_mode = 'version-1'
        self.run_tool()
        self.assertTrue(self.receipt()['success'])
        self.assertEqual(self.receipt()['recordingSeconds'], 38)

    def test_movie_without_header_has_no_duration(self):
        path = self.root / 'frames-only.mp4'
        path.write_bytes(box(b'ftyp', b'qt  ') + box(b'mdat', b'frames'))
        self.assertIsNone(runner.movie_seconds(path))

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

    def test_ui_runs_from_screenshots_xctestrun_copy(self):
        original = self.xctestrun.read_bytes()
        self.run_tool()
        self.assertTrue(self.receipt()['success'])
        copy = self.xctestrun.with_name(runner.SCREENSHOTS_XCTESTRUN)
        targets = plistlib.loads(copy.read_bytes())['TestConfigurations'][0]['TestTargets']
        self.assertEqual([t['PreferredScreenCaptureFormat'] for t in targets], ['screenshots'] * 2)
        self.assertEqual(self.xctestrun.read_bytes(), original, 'The built xctestrun must stay unchanged')
        self.assertEqual(self.receipt()['screenCaptureFormatsBefore'], ['screenRecording'])
        ui = next(c for c in self.commands if 'test-without-building' in c)
        self.assertEqual(ui[ui.index('-xctestrun') + 1], str(copy))
        self.assertNotIn('-scheme', ui)
        self.assertNotIn('-project', ui)
        for option in ['-collect-test-diagnostics', '-parallel-testing-enabled', '-enableCodeCoverage']:
            self.assertIn(option, ui)
        self.assertIn('-only-testing:unipadUITests/PlayPadLayoutTests/testSyntheticPackInputAutoplayAndExit', ui)

    def test_rerun_ignores_previous_screenshots_copy(self):
        self.run_tool()
        self.commands.clear()
        self.out = self.root / 'out-2'
        self.run_tool()
        self.assertTrue(self.receipt()['success'])

    def assert_xctestrun_rejected_before_ui(self):
        with self.assertRaisesRegex(RuntimeError, 'xctestrun'):
            self.run_tool()
        self.assert_cleaned()
        self.assert_failed()
        self.assertFalse(any('test-without-building' in c for c in self.commands))
        self.assertFalse(any('recordVideo' in c for c in self.commands))

    def test_missing_xctestrun_stops_before_ui(self):
        self.xctestrun.unlink()
        self.assert_xctestrun_rejected_before_ui()

    def test_two_xctestruns_from_overlay_build_stop_before_ui(self):
        other = self.xctestrun.with_name('other.xctestrun')
        other.write_bytes(self.xctestrun.read_bytes())
        self.built_xctestruns.append(other)
        self.assert_xctestrun_rejected_before_ui()

    def test_xctestrun_from_earlier_build_ignored(self):
        # A generic-destination build leaves an arm64-x86_64 file in the same folder.
        earlier = self.xctestrun.with_name('unipad_unipad_iphonesimulator27.0-arm64-x86_64.xctestrun')
        earlier.write_bytes(self.xctestrun.read_bytes())
        os.utime(earlier, (0, 0))
        self.run_tool()
        self.assertTrue(self.receipt()['success'])
        self.assertEqual(self.receipt()['xctestrun'], self.xctestrun.name)

    def test_xctestrun_not_written_by_overlay_build_stops_before_ui(self):
        self.built_xctestruns = []
        self.assert_xctestrun_rejected_before_ui()

    def test_xctestrun_without_test_targets_stops_before_ui(self):
        self.xctestrun.write_bytes(plistlib.dumps({'__xctestrun_metadata__': {'FormatVersion': 2}, 'TestConfigurations': []}))
        self.assert_xctestrun_rejected_before_ui()

    def test_success_counts_product_files_and_preserves_library(self):
        self.run_tool()
        self.assert_cleaned()
        self.assertEqual(self.receipt()['unchangedProductFiles'], len(self.baseline_files))
        self.assertTrue(self.receipt()['libraryRestored'])
        self.assertTrue(self.receipt()['success'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
