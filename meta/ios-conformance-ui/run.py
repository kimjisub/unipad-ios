"""Run the AP-001 UI overlay in an archived baseline, on a harness-lent UDID.

Source/build/output directories must be under PAPERCLIP_RUN_SCRATCH_DIR.
The caller first runs devices.py up-ios. This command always returns the device.
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


def invoke(command, log=None, check=True, timeout=None):
    if log:
        with log.open('w') as f:
            result = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
    else:
        result = subprocess.run(command, capture_output=True, text=True)
    if check and result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {command}; log={log}')
    return result


def hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()}


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--pack', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path(os.environ['PAPERCLIP_RUN_SCRATCH_DIR']).resolve()
    for path in [args.source, args.derived_data, args.out]:
        if not path.resolve().is_relative_to(scratch):
            parser.error('Source, build and output must be in this run scratch directory')
    args.out.mkdir(parents=True, exist_ok=True)
    staged = None
    library = None
    before = None
    video = None
    receipt = {'baseline': BASELINE, 'udid': args.udid,
               'packSha256': hashlib.sha256(args.pack.read_bytes()).hexdigest(),
               'launchArguments': ['-UniPadFirebaseLocalOnly', 'YES', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'],
               'commands': [], 'startedAt': time.time()}
    build = args.derived_data / 'Build/Products/Debug-iphonesimulator'
    try:
        if receipt['packSha256'] != AP001_SHA256:
            raise RuntimeError('Use the unchanged AP-001 ZIP from the parent evidence')
        # Check all product source/resource bytes before any build or launch.
        files = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', BASELINE], cwd=TOOLS).decode().splitlines()
        product_files = [p for p in files if p.startswith('unipad/')]
        changed = [p for p in product_files if (args.source / p).read_bytes() !=
                   subprocess.check_output(['git', 'show', f'{BASELINE}:{p}'], cwd=TOOLS)]
        if changed:
            raise RuntimeError(f'Product baseline differs: {changed}')
        receipt['unchangedProductFiles'] = len(product_files)
        if (build / 'unipad.app').exists():
            receipt['appBeforeOverlay'] = hashes(build / 'unipad.app')
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
        container = Path(invoke(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']).stdout.strip())
        library = container / 'Documents/UniPack'
        before = hashes(library)
        save(args.out / 'library-before.json', before)
        # Duplicate exact titles must never be resolved by choosing the first match.
        existing = [p for p in library.glob('*/info') if 'title=Conformance' in p.read_text()]
        if existing:
            raise RuntimeError('A Conformance fixture is already installed; preserve it and stop')
        staged = library / ('JIS-70-' + os.environ['PAPERCLIP_RUN_ID'])
        staged.mkdir()  # No overwrite or deletion of existing content.
        with zipfile.ZipFile(args.pack) as archive:
            for item in archive.infolist():
                if not (staged / item.filename).resolve().is_relative_to(staged.resolve()):
                    raise RuntimeError('Unsafe fixture path')
            archive.extractall(staged)
        receipt['stagedName'] = staged.name
        receipt['stagedFiles'] = hashes(staged)
        receipt['recordingStartedAt'] = time.time()
        recording_log = (args.out / 'recording.log').open('w')
        video = subprocess.Popen(['xcrun', 'simctl', 'io', args.udid, 'recordVideo', '--codec=h264',
                                  str(args.out / 'walkthrough.mp4')], stdout=recording_log, stderr=subprocess.STDOUT)
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
    finally:
        try:
            if video:
                video.send_signal(signal.SIGINT)
                video.wait(timeout=30)
            invoke(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
            # Xcode reinstalls the app for UI tests and may relocate the container.
            # Resolve it again instead of reading or cleaning the now-stale path.
            if library is not None:
                current = invoke(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data'])
                library = Path(current.stdout.strip()) / 'Documents/UniPack'
            if staged is not None:
                staged = library / staged.name
                if staged.exists():
                    receipt['stagedFilesAfter'] = hashes(staged)
                    shutil.rmtree(staged)
            if before is not None:
                after = hashes(library)
                save(args.out / 'library-after.json', after)
                receipt['libraryRestored'] = after == before
                receipt['libraryFiles'] = len(before)
            receipt['finishedAt'] = time.time()
            save(args.out / 'receipt.json', receipt)
        finally:
            invoke(['python3', str(Path(os.environ['HARNESS']) / 'devices.py'), 'down'], args.out / 'devices-down.log')
        if before is not None and after != before:
            raise RuntimeError('Existing library changed; investigate without overwriting it')


if __name__ == '__main__':
    main()
