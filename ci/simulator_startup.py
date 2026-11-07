"""Start a caller-selected simulator early, then wait for it before testing.

Only an existing, available device with the exact supplied UDID is used.
Starting it before compilation lets simulator services settle while builds run.
"""
import argparse
import json
import subprocess


def prepare(action, udid):
    listing = subprocess.run(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'],
        check=True, capture_output=True, text=True,
    )
    devices = json.loads(listing.stdout)['devices']
    device = next((device for items in devices.values() for device in items
                   if device['udid'] == udid and device.get('isAvailable')), None)
    if device is None:
        raise RuntimeError(f'Selected simulator {udid} is not available')
    state = device['state']
    if action == 'start' and state == 'Shutdown':
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True)
    elif state not in ('Booting', 'Booted'):
        raise RuntimeError(f'Selected simulator {udid} is {state}; start it before building')
    if action == 'wait':
        subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'wait'])
    parser.add_argument('udid')
    args = parser.parse_args()
    prepare(args.action, args.udid)


if __name__ == '__main__':
    main()
