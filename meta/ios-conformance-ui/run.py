"""Run the AP-001 UI overlay in an archived baseline, on a harness-lent UDID.

Source/build/output directories must be under PAPERCLIP_RUN_SCRATCH_DIR.
The caller first runs devices.py up-ios. After argument parsing, this command
always attempts device return and reports any cleanup failure.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import time
import zipfile

BASELINE = '5dd4cac10f3ede280c9f5207e949a46b624c297f'
BUNDLE = 'kim.jisub.unipad'
AP001_SHA256 = 'fecc1cd0f58e0153751dd58574bc39b98b6e0f4e4fad86ca617ca24cf71f16b5'
TOOLS = Path(__file__).resolve().parent
# Xcode writes these workspace artifacts even with derived data kept elsewhere.
# Only untracked regular files at these exact paths are exempt; tracked inputs
# still undergo byte comparison, and other files in these directories fail.
XCODE_GENERATED_FILES = {
    'unipad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
    'unipad.xcodeproj/project.xcworkspace/contents.xcworkspacedata',
    'unipad.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist',
}


def invoke(command, log=None, check=True, timeout=None):
    if log:
        with log.open('w') as f:
            result = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
    else:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {command}; log={log}')
    return result


def hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()}


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))


def check_product(source):
    # Compare the entire archived tree: synchronized Swift groups pick up new
    # files, and themes/project/test support live outside the unipad directory.
    files = subprocess.check_output(
        ['git', 'ls-tree', '-r', '--name-only', '--full-tree', '-z', BASELINE], cwd=TOOLS
    ).decode().split('\0')
    baseline_files = {p for p in files if p}
    if not baseline_files or not any(p.startswith('unipad/') for p in baseline_files):
        raise RuntimeError('Product baseline file list is empty; refuse to build or launch')
    actual_files = {str(p.relative_to(source)) for p in source.rglob('*')
                    if not p.is_dir() or p.is_symlink()}
    added = sorted(name for name in actual_files - baseline_files
                   if name not in XCODE_GENERATED_FILES
                   or (source / name).is_symlink() or not (source / name).is_file())
    missing = sorted(baseline_files - actual_files)
    changed = []
    overlay = 'unipadUITests/PlayPadLayoutTests.swift'
    for name in sorted(baseline_files & actual_files):
        path = source / name
        if path.is_symlink() or not path.is_file():
            changed.append(name)
            continue
        content = path.read_bytes()
        baseline = subprocess.check_output(['git', 'show', f'{BASELINE}:{name}'], cwd=TOOLS)
        if content != baseline and not (
                name == overlay and content == (TOOLS / 'PlayPadLayoutTests.swift').read_bytes()):
            changed.append(name)
    if added or missing or changed:
        raise RuntimeError(f'Product baseline differs: added={added}; missing={missing}; changed={changed}')
    return len(baseline_files)


def finish_recording(video, path, receipt):
    try:
        if video.poll() is None:
            video.send_signal(signal.SIGINT)
        code = video.wait(timeout=30)
    except Exception:
        # A hung recorder must not block library cleanup or device return.
        video.kill()
        video.wait(timeout=10)
        raise
    receipt['recordingExitCode'] = code
    if code != 0 or not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError(f'Screen recording failed or missing: exit={code}; {path}')
    receipt['recordingSha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    receipt['recordingBytes'] = path.stat().st_size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--pack', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    staged = None
    library = None
    before = None
    video = None
    evidence_out = None
    failure = None
    cleanup_errors = []
    receipt = {'baseline': BASELINE, 'udid': args.udid,
               'launchArguments': ['-UniPadFirebaseLocalOnly', 'YES', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'],
               'commands': [], 'startedAt': time.time()}
    build = args.derived_data / 'Build/Products/Debug-iphonesimulator'
    try:
        scratch = Path(os.environ['PAPERCLIP_RUN_SCRATCH_DIR']).resolve()
        for path in [args.source, args.derived_data, args.out]:
            if not path.resolve().is_relative_to(scratch):
                raise RuntimeError('Source, build and output must be in this run scratch directory')
        args.out.mkdir(parents=True)  # Fresh evidence only; never accept a stale video.
        evidence_out = args.out
        receipt['packSha256'] = hashlib.sha256(args.pack.read_bytes()).hexdigest()
        if receipt['packSha256'] != AP001_SHA256:
            raise RuntimeError('Use the unchanged AP-001 ZIP from the parent evidence')
        # Check all product source/resource bytes before any build or launch.
        receipt['unchangedProductFiles'] = check_product(args.source)
        if (build / 'unipad.app').exists():
            receipt['appBeforeOverlay'] = hashes(build / 'unipad.app')
        if (build / 'unipadUITests-Runner.app').exists():
            receipt['runnerBeforeOverlay'] = hashes(build / 'unipadUITests-Runner.app')
        shutil.copyfile(TOOLS / 'PlayPadLayoutTests.swift', args.source / 'unipadUITests/PlayPadLayoutTests.swift')
        command = ['xcodebuild', 'build-for-testing', '-project', str(args.source / 'unipad.xcodeproj'),
                   '-scheme', 'unipad', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
                   '-destination', f'platform=iOS Simulator,id={args.udid}',
                   '-derivedDataPath', str(args.derived_data), 'CODE_SIGNING_ALLOWED=NO']
        receipt['commands'].append(command)
        invoke(command, args.out / 'overlay-build.log')
        receipt['appAfterOverlay'] = hashes(build / 'unipad.app')
        receipt['runner'] = hashes(build / 'unipadUITests-Runner.app')
        info = plistlib.loads((build / 'unipad.app/Info.plist').read_bytes())
        receipt['version'] = info['CFBundleShortVersionString']
        receipt['build'] = info['CFBundleVersion']
        invoke(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
        invoke(['xcrun', 'simctl', 'install', args.udid, str(build / 'unipad.app')])
        container_path = invoke(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']).stdout.strip()
        if not container_path:
            raise RuntimeError('Installed app container is empty')
        container = Path(container_path)
        library = container / 'Documents/UniPack'
        if not library.is_dir():
            raise RuntimeError('This route requires the existing shared UniPack library')
        before = hashes(library)
        save(args.out / 'library-before.json', before)
        # Duplicate exact titles must never be resolved by choosing the first match.
        existing = [p for p in library.glob('*/info') if 'title=Conformance' in p.read_text()]
        if existing:
            raise RuntimeError('A Conformance fixture is already installed; preserve it and stop')
        candidate = library / ('JIS-70-' + os.environ['PAPERCLIP_RUN_ID'])
        candidate.mkdir()  # No overwrite or deletion of existing content.
        staged = candidate  # Register cleanup ownership only after successful creation.
        with zipfile.ZipFile(args.pack) as archive:
            for item in archive.infolist():
                if not (staged / item.filename).resolve().is_relative_to(staged.resolve()):
                    raise RuntimeError('Unsafe fixture path')
            archive.extractall(staged)
        receipt['stagedName'] = staged.name
        receipt['stagedFiles'] = hashes(staged)
        receipt['recordingStartedAt'] = time.time()
        with (args.out / 'recording.log').open('w') as recording_log:
            video = subprocess.Popen(['xcrun', 'simctl', 'io', args.udid, 'recordVideo', '--codec=h264',
                                      str(args.out / 'walkthrough.mp4')], stdout=recording_log, stderr=subprocess.STDOUT)
        time.sleep(0.5)
        if video.poll() is not None:
            raise RuntimeError('Screen recording exited before UI execution; see recording.log')
        command = ['xcodebuild', 'test-without-building', '-project', str(args.source / 'unipad.xcodeproj'),
                   '-scheme', 'unipad', '-configuration', 'Debug', '-destination', f'platform=iOS Simulator,id={args.udid}',
                   '-derivedDataPath', str(args.derived_data), '-parallel-testing-enabled', 'NO', '-enableCodeCoverage', 'NO',
                   '-collect-test-diagnostics', 'never',
                   '-only-testing:unipadUITests/PlayPadLayoutTests/testSyntheticPackInputAutoplayAndExit',
                   '-resultBundlePath', str(args.out / 'result.xcresult'), 'CODE_SIGNING_ALLOWED=NO']
        receipt['commands'].append(command)
        result = invoke(command, args.out / 'test.log', check=False, timeout=180)
        receipt['testExitCode'] = result.returncode
        if result.returncode:
            raise RuntimeError('UI execution failed; see test.log')
    except BaseException as error:
        failure = error
        receipt['executionError'] = f'{type(error).__name__}: {error}'
    finally:
        def attempt(step, action):
            try:
                action()
            except Exception as error:
                cleanup_errors.append({'step': step, 'error': f'{type(error).__name__}: {error}'})

        if video is not None:
            attempt('recording', lambda: finish_recording(video, args.out / 'walkthrough.mp4', receipt))
        attempt('app termination', lambda: invoke(
            ['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False, timeout=30))

        def restore_library():
            # Xcode may relocate the container. Never delete from an unconfirmed path.
            current = invoke(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data'], timeout=30)
            if not current.stdout.strip():
                raise RuntimeError('Current app container is empty; preserve fixture for inspection')
            current_library = Path(current.stdout.strip()) / 'Documents/UniPack'
            if not current_library.is_dir():
                raise RuntimeError('Current library is unavailable; preserve fixture for inspection')
            if staged is not None:
                current_staged = current_library / staged.name
                if current_staged.exists():
                    receipt['stagedFilesAfter'] = hashes(current_staged)
                    shutil.rmtree(current_staged)
            after = hashes(current_library)
            save(args.out / 'library-after.json', after)
            receipt['libraryRestored'] = after == before
            receipt['libraryFiles'] = len(before)
            if after != before:
                raise RuntimeError('Existing library changed; investigate without overwriting it')

        if before is not None:
            attempt('library restoration', restore_library)

        def return_device():
            invoke(['python3', str(Path(os.environ['HARNESS']) / 'devices.py'), 'down'],
                   evidence_out / 'devices-down.log' if evidence_out else None, timeout=60)
            receipt['deviceReturned'] = True

        attempt('device return', return_device)
        receipt['cleanupErrors'] = cleanup_errors
        receipt['finishedAt'] = time.time()
        receipt['success'] = failure is None and not cleanup_errors
        if evidence_out is not None:
            attempt('receipt saving', lambda: save(evidence_out / 'receipt.json', receipt))
    if failure is not None or cleanup_errors:
        raise RuntimeError(f'Execution failed: {failure}; cleanup errors: {cleanup_errors}') from failure


if __name__ == '__main__':
    main()
