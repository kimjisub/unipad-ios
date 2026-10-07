"""Run a fingerprint-approved synthetic-pack UI overlay in an archived baseline, on a harness-lent UDID.

Source/build directories must be under PAPERCLIP_RUN_SCRATCH_DIR. Output must be fresh.
The caller first runs devices.py up-ios. After argument parsing, this command
attempts device return unless --keep-device leaves it with the caller.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import struct
import subprocess
import time
import zipfile

BASELINE = '5dd4cac10f3ede280c9f5207e949a46b624c297f'
BUNDLE = 'kim.jisub.unipad'
TOOLS = Path(__file__).resolve().parent
# Written beside the built xctestrun because its __TESTROOT__ is that folder.
SCREENSHOTS_XCTESTRUN = 'conformance-screenshots.xctestrun'
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


def read_info(path):
    # Match 5dd4cac UniPackFolder.readTextFile: UTF-8, BOM-marked UTF-16,
    # EUC-KR, then CP949. Never guess a title from an unreadable info file.
    try:
        data = path.read_bytes()
    except OSError as error:
        raise RuntimeError(f'Cannot decode info: {path}') from error
    encodings = ['utf-8']
    if data.startswith((b'\xfe\xff', b'\xff\xfe')):
        encodings.append('utf-16')
    encodings.extend(['euc-kr', 'cp949'])
    for encoding in encodings:
        try:
            text = data.decode(encoding)
            return text[1:] if text.startswith('\ufeff') else text
        except UnicodeError:
            continue
    raise RuntimeError(f'Cannot decode info: {path}')


def folder_title(folder):
    # checkFile compares names case-insensitively and prefers info to info.json.
    info = None
    info_json = None
    for item in folder.iterdir():
        if item.is_dir():
            continue
        if item.name.lower() == 'info':
            info = item
        elif item.name.lower() == 'info.json':
            info_json = item
    title = ''
    if info is not None:
        for raw_line in read_info(info).splitlines():
            # Swift split skips leading empty components without using maxSplits.
            # Keep any further '=' in the value after the first nonempty key.
            parts = raw_line.strip().lstrip('=').split('=', 1)
            # Empty trailing components are omitted before key/value trimming.
            if len(parts) == 2 and all(parts):
                key, value = (part.strip() for part in parts)
                if key == 'title':
                    title = value
    elif info_json is not None:
        try:
            data = json.loads(info_json.read_bytes())
        except (OSError, ValueError) as error:
            raise RuntimeError(f'Cannot decode info.json: {info_json}') from error
        if not isinstance(data, dict):
            raise RuntimeError(f'Cannot decode info.json object: {info_json}')
        if isinstance(data.get('title'), str):
            title = data['title']
    return title


def conformance_folders(library, title='Conformance'):
    return [folder for folder in library.iterdir()
            if folder.is_dir() and folder_title(folder) == title]


def load_baseline():
    manifest = json.loads((TOOLS / 'baseline-fingerprints.json').read_text())
    if manifest['commit'] != BASELINE:
        raise RuntimeError('Unexpected product baseline commit')
    return manifest['files']


def approved_pack(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    approved = json.loads((TOOLS / 'pack-fingerprints.json').read_text())
    matches = [name for name, value in approved.items() if value == digest]
    if len(matches) != 1:
        raise RuntimeError('Use an unchanged ZIP from the approved 20-pack sample')
    return matches[0], digest


def fixture_title(path):
    # Reuse the same product metadata decoding for the ZIP and library folders.
    import tempfile
    with tempfile.TemporaryDirectory(dir=os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) as directory:
        folder = Path(directory)
        with zipfile.ZipFile(path) as archive:
            for item in archive.infolist():
                if '/' not in item.filename and item.filename.lower() in ('info', 'info.json'):
                    (folder / item.filename).write_bytes(archive.read(item))
        return folder_title(folder)


def check_product(source):
    # A committed path/hash manifest allows execution outside a git checkout.
    fingerprints = load_baseline()
    baseline_files = set(fingerprints)
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
        if hashlib.sha256(content).hexdigest() != fingerprints[name] and not (
                name == overlay and content == (TOOLS / 'PlayPadLayoutTests.swift').read_bytes()):
            changed.append(name)
    if added or missing or changed:
        raise RuntimeError(f'Product baseline differs: added={added}; missing={missing}; changed={changed}')
    return len(baseline_files)


def screenshots_xctestrun(products, built_since, receipt):
    """Copy the built xctestrun with XCTest's own screen recording turned off.

    When the test runner stops its recording twice, the host's SimRenderServer
    crashes and CoreSimulator shuts the simulator down right after a passing
    test. Screenshots keep XCTest's failure evidence without that recording;
    the walkthrough video comes from simctl. Product files stay unchanged.
    Every build-for-testing rewrites its xctestrun; files left by builds for
    other destinations in the same derived data are older and ignored.
    """
    built = sorted(p for p in products.glob('*.xctestrun')
                   if p.name != SCREENSHOTS_XCTESTRUN and p.stat().st_mtime >= built_since)
    if len(built) != 1:
        raise RuntimeError(f'Expected one xctestrun written by the overlay build in {products}; '
                           f'found {[p.name for p in built]}')
    plist = plistlib.loads(built[0].read_bytes())
    targets = [target for configuration in plist.get('TestConfigurations', [])
               for target in configuration.get('TestTargets', [])]
    if plist.get('__xctestrun_metadata__', {}).get('FormatVersion') != 2 or not targets:
        raise RuntimeError(f'Unsupported xctestrun layout: {built[0].name}')
    receipt['xctestrun'] = built[0].name
    receipt['xctestrunSha256'] = hashlib.sha256(built[0].read_bytes()).hexdigest()
    receipt['screenCaptureFormatsBefore'] = sorted({target.get('PreferredScreenCaptureFormat', '')
                                                    for target in targets})
    for target in targets:
        target['PreferredScreenCaptureFormat'] = 'screenshots'
    copy = products / SCREENSHOTS_XCTESTRUN
    copy.write_bytes(plistlib.dumps(plist))
    receipt['screenshotsXctestrunSha256'] = hashlib.sha256(copy.read_bytes()).hexdigest()
    return copy


def movie_seconds(path):
    """Duration from a finalized QuickTime/MP4 movie header, or None.

    A finalized file is a chain of top-level boxes that ends exactly at the
    end of the file and holds both the frames (`mdat`) and the movie header
    (`moov/mvhd`); an interrupted or cut-off recording fails one of these.
    """
    data = path.read_bytes()

    def boxes(start, end):
        while start + 8 <= end:
            size, kind = struct.unpack('>I4s', data[start:start + 8])
            header = 8
            if size == 1 and start + 16 <= end:
                size, header = struct.unpack('>Q', data[start + 8:start + 16])[0], 16
            elif size == 0:
                size = end - start
            if size < header or start + size > end:
                return
            yield kind, start + header, start + size
            start += size

    top = list(boxes(0, len(data)))
    kinds = {kind for kind, _, _ in top}
    if not top or top[-1][2] != len(data) or not {b'moov', b'mdat'} <= kinds:
        return None
    for kind, body, end in top:
        if kind != b'moov':
            continue
        for inner, header, _ in boxes(body, end):
            if inner == b'mvhd':
                if data[header] == 1:
                    timescale, duration = struct.unpack('>IQ', data[header + 20:header + 32])
                else:
                    timescale, duration = struct.unpack('>II', data[header + 12:header + 20])
                return duration / timescale if timescale else None
    return None


def finish_recording(video, path, receipt):
    hung = False
    try:
        if video.poll() is None:
            video.send_signal(signal.SIGINT)
        try:
            code = video.wait(timeout=30)
        except subprocess.TimeoutExpired:
            # simctl can finalize the movie and then never exit (seen 2026-10-07);
            # the file below decides whether the recording is usable.
            hung = True
            video.kill()
            code = video.wait(timeout=10)
    except Exception:
        # A hung recorder must not block library cleanup or device return.
        video.kill()
        video.wait(timeout=10)
        raise
    receipt['recordingExitCode'] = code
    receipt['recordingHungAfterStop'] = hung
    seconds = movie_seconds(path) if path.is_file() else None
    receipt['recordingSeconds'] = seconds
    if (code != 0 and not hung) or not seconds:
        raise RuntimeError(f'Screen recording failed, missing or not finalized: exit={code}; '
                           f'hung={hung}; seconds={seconds}; {path}')
    receipt['recordingSha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    receipt['recordingBytes'] = path.stat().st_size


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--pack', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--keep-device', action='store_true', help='Caller returns its devices after a batch')
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
        for path in [args.source, args.derived_data]:
            if not path.resolve().is_relative_to(scratch):
                raise RuntimeError('Source and build must be in this run scratch directory')
        args.out.mkdir(parents=True)  # Fresh evidence only; never accept a stale video.
        evidence_out = args.out
        receipt['sample'], receipt['packSha256'] = approved_pack(args.pack)
        receipt['fixtureTitle'] = fixture_title(args.pack)
        staged_name = 'Conformance-' + os.environ['PAPERCLIP_RUN_ID']
        receipt['selectionTitle'] = receipt['fixtureTitle']
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
        build_started = time.time()
        invoke(command, args.out / 'overlay-build.log')
        xctestrun = screenshots_xctestrun(args.derived_data / 'Build/Products', build_started, receipt)
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
        existing = conformance_folders(library, receipt['selectionTitle'])
        receipt['existingConformanceCount'] = len(existing)
        if existing:
            raise RuntimeError(f"A fixture with title {receipt['selectionTitle']!r} is already installed; preserve it and stop")
        candidate = library / staged_name
        candidate.mkdir()  # No overwrite or deletion of existing content.
        staged = candidate  # Register cleanup ownership only after successful creation.
        with zipfile.ZipFile(args.pack) as archive:
            for item in archive.infolist():
                if not (staged / item.filename).resolve().is_relative_to(staged.resolve()):
                    raise RuntimeError('Unsafe fixture path')
            archive.extractall(staged)
        receipt['stagedName'] = staged.name
        receipt['stagedFiles'] = hashes(staged)
        receipt['stagedConformanceCount'] = len(conformance_folders(library, receipt['selectionTitle']))
        if receipt['stagedConformanceCount'] != 1:
            raise RuntimeError(f"Expected exactly one {receipt['selectionTitle']} title after staging; stop before UI execution")
        with zipfile.ZipFile(args.pack) as archive:
            has_autoplay = any(n.lower() == 'autoplay' for n in archive.namelist())
        receipt['hasAutoplayFile'] = has_autoplay
        plist = plistlib.loads(xctestrun.read_bytes())
        for configuration in plist['TestConfigurations']:
            for target in configuration['TestTargets']:
                target.setdefault('EnvironmentVariables', {}).update({
                    'CONFORMANCE_TITLE': receipt['selectionTitle'],
                    'CONFORMANCE_SAMPLE': receipt['sample'],
                    'CONFORMANCE_HAS_AUTOPLAY': 'YES' if has_autoplay else 'NO'})
        xctestrun.write_bytes(plistlib.dumps(plist))
        receipt['screenshotsXctestrunSha256'] = hashlib.sha256(xctestrun.read_bytes()).hexdigest()
        receipt['recordingStartedAt'] = time.time()
        with (args.out / 'recording.log').open('w') as recording_log:
            video = subprocess.Popen(['xcrun', 'simctl', 'io', args.udid, 'recordVideo', '--codec=h264',
                                      str(args.out / 'walkthrough.mp4')], stdout=recording_log, stderr=subprocess.STDOUT)
        time.sleep(0.5)
        if video.poll() is not None:
            raise RuntimeError('Screen recording exited before UI execution; see recording.log')
        command = ['xcodebuild', 'test-without-building', '-xctestrun', str(xctestrun),
                   '-destination', f'platform=iOS Simulator,id={args.udid}',
                   '-derivedDataPath', str(args.derived_data), '-parallel-testing-enabled', 'NO', '-enableCodeCoverage', 'NO',
                   '-collect-test-diagnostics', 'never',
                   '-only-testing:unipadUITests/PlayPadLayoutTests/testSyntheticPackInputAutoplayAndExit',
                   '-resultBundlePath', str(args.out / 'result.xcresult'), 'CODE_SIGNING_ALLOWED=NO']
        receipt['commands'].append(command)
        result = invoke(command, args.out / 'test.log', check=False, timeout=420)
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

        receipt['deviceReturned'] = False
        receipt['deviceReturnDeferred'] = args.keep_device
        if not args.keep_device:
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
