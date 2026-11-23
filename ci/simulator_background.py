"""Reduce first-boot work on disposable CI simulators, before their first boot.

CoreSimulator's per-device launchd override store is an undocumented host-side
detail. Keep this opt-in, merge existing entries and verify the live state after
boot. Only wallpaper previews and widgets are disabled; app, test, networking,
audio and diagnostic services are untouched.
"""
from pathlib import Path
import os
import plistlib
import re
import subprocess
from uuid import UUID


SERVICES = ('com.apple.PosterBoard', 'com.apple.chronod')
STORE = Path('/private/var/tmp')


def prepare(udid, store=STORE):
    # Validate before using a caller-supplied identifier in a host path.
    if str(UUID(udid)).upper() != udid.upper():
        raise ValueError('expected a simulator UUID')
    directory = store / f'com.apple.CoreSimulator.SimDevice.{udid}'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = directory / 'disabled.plist'
    values = plistlib.loads(path.read_bytes()) if path.exists() else {}
    if not isinstance(values, dict):
        raise ValueError('simulator launchd overrides must be a dictionary')
    values.update(dict.fromkeys(SERVICES, True))
    temporary = directory / f'disabled.plist.{os.getpid()}.tmp'
    try:
        temporary.write_bytes(plistlib.dumps(values, fmt=plistlib.FMT_BINARY))
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    print(f'Simulator background profile prepared for {udid}: {", ".join(SERVICES)}', flush=True)


def verify(udid):
    command = ['xcrun', 'simctl', 'spawn', udid, 'launchctl']
    disabled = subprocess.run(command + ['print-disabled', 'system'], check=True,
                              capture_output=True, text=True).stdout
    print(disabled, flush=True)
    for label in SERVICES:
        if not re.search(r'"' + re.escape(label) + r'"\s*=>\s*true\b', disabled):
            raise RuntimeError(f'background profile not applied: {label} is not disabled')
        loaded = subprocess.run(command + ['print', 'system/' + label],
                                capture_output=True, text=True)
        # launchctl reports a missing service as 113 (or 3 on older runtimes).
        # Other failures do not establish that the service is absent.
        if loaded.returncode not in (3, 113):
            raise RuntimeError(f'background profile not verified: {label}, exit {loaded.returncode}: '
                               f'{loaded.stdout}{loaded.stderr}')
        print(f'Simulator background profile verified: {label} disabled and not loaded', flush=True)
