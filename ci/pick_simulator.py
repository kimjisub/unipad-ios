"""Print the UDID of an iPhone simulator the selected Xcode can run.

CI images carry simulator runtimes newer than the selected Xcode supports, so only runtimes
up to the iOS Simulator SDK version count. The newest of those wins, then the preferred
model, then the first iPhone by name so the choice does not depend on list order.
"""
import argparse
import json
import re
import subprocess
import sys

RUNTIME_VERSION = re.compile(r'\.iOS-(\d+(?:-\d+)*)$')


def version(text, separator):
    return tuple(int(part) for part in text.split(separator))


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
        candidates.extend((runtime_version, device) for device in items
                          if device.get('isAvailable') and device['name'].startswith('iPhone'))
    if not candidates:
        return None
    newest = max(runtime_version for runtime_version, _ in candidates)
    iphones = sorted((device for runtime_version, device in candidates if runtime_version == newest),
                     key=lambda device: device['name'])
    return next((device for device in iphones if device['name'] == preferred), iphones[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preferred', default='iPhone 17')
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
