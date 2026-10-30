"""Print the UDID of an iPhone simulator the selected Xcode can run.

CI images carry simulator runtimes newer than the selected Xcode supports, so only runtimes
up to the iOS Simulator SDK version count. The first preferred model found wins, on the newest
runtime that has it; a newer runtime holding only other models does not displace it. Without
any preferred model, the first iPhone by name on the newest runtime is used so the choice does
not depend on list order.
"""
import argparse
import json
import re
import subprocess
import sys

RUNTIME_VERSION = re.compile(r'\.iOS-(\d+(?:-\d+)*)$')


def version(text, separator):
    """Major and minor only: a runtime such as iOS-27-1-1 still runs with the 27.1 SDK."""
    return tuple(int(part) for part in text.split(separator))[:2]


def pick(devices, sdk, preferred):
    limit = version(sdk, '.')
    candidates = []
    for runtime, items in devices.items():
        match = RUNTIME_VERSION.search(runtime)
        if not match:
            continue
        runtime_version = version(match.group(1), '-')
        if runtime_version > limit:
            continue
        candidates.extend((runtime_version, device['name'], device) for device in items
                          if device.get('isAvailable') and device['name'].startswith('iPhone'))
    if not candidates:
        return None
    for name in preferred:
        matches = [candidate for candidate in candidates if candidate[1] == name]
        if matches:
            return max(matches, key=lambda candidate: candidate[0])[2]
    newest = max(candidate[0] for candidate in candidates)
    return min((candidate for candidate in candidates if candidate[0] == newest),
               key=lambda candidate: candidate[1])[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preferred', action='append', default=[],
                        help='model name to prefer; repeat in order of preference')
    args = parser.parse_args()
    sdk = subprocess.check_output(
        ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True
    ).strip()
    devices = json.loads(subprocess.check_output(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '--json']
    ))['devices']
    device = pick(devices, sdk, args.preferred)
    if device is None:
        sys.exit(f'No available iPhone simulator on iOS {sdk} or older')
    print(f"Using {device['name']} ({device['udid']})", file=sys.stderr)
    print(device['udid'])


if __name__ == '__main__':
    main()
