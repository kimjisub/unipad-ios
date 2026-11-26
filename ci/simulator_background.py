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

    def query(*arguments):
        result = subprocess.run(command + list(arguments), capture_output=True, text=True)
        print(f'launchctl {" ".join(arguments)}: exit {result.returncode}\n'
              f'{result.stdout}{result.stderr}', flush=True)
        return result

    manager = query('manageruid')
    uid = manager.stdout.strip()
    if manager.returncode != 0 or not re.fullmatch(r'[1-9][0-9]*', uid):
        raise RuntimeError('cannot determine the simulator user domain')
    user_domain = f'user/{uid}'
    # These services belong to the simulator's user domain. Establish that the
    # domain exists before treating a missing-service error as evidence of absence.
    if query('print', user_domain).returncode != 0:
        raise RuntimeError(f'cannot inspect simulator domain {user_domain}')
    for domain in ('system', user_domain):
        disabled = query('print-disabled', domain)
        if disabled.returncode != 0:
            raise RuntimeError(f'cannot inspect disabled services in {domain}')
        for label in SERVICES:
            if not re.search(r'"' + re.escape(label) + r'"\s*=>\s*(?:true|disabled)\b',
                             disabled.stdout):
                raise RuntimeError(f'background profile not applied: {domain}/{label} is not disabled')
            loaded = query('print', f'{domain}/{label}')
            # A missing domain or an unrelated query error is not proof that a
            # service is absent, even when launchctl returns the same exit code.
            if (loaded.returncode not in (3, 113)
                    or 'Could not find service' not in loaded.stderr):
                raise RuntimeError(f'background profile not verified: {domain}/{label}')
    for label in SERVICES:
        print(f'Simulator background profile verified: {label} disabled and not loaded '
              f'in system and {user_domain}', flush=True)
