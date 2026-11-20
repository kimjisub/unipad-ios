"""Boot the selected simulator and wait until the machine has settled before tests start.

A simulator's first boot keeps the CI runner busy for minutes after it reports booted:
its widgets, wallpapers and background services start for the first time. Tests with
time limits that run meanwhile fail on time alone. Settled means the runner's 1-minute
load average stayed at or below the threshold (by default the number of CPU cores) for
the whole hold. The wait never fails the job: at the limit the tests start anyway.
The last line printed says how long it waited and why it ended.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone

LIMIT_CEILING = 480


@dataclass(frozen=True)
class Settle:
    threshold: float
    hold: float
    limit: float
    interval: float

    def __post_init__(self):
        if not 0 < self.limit <= LIMIT_CEILING:
            raise ValueError(f'limit must be within {LIMIT_CEILING} s, got {self.limit}')
        if self.hold <= 0 or self.interval <= 0:
            raise ValueError('hold and interval must be positive')


@dataclass(frozen=True)
class Result:
    waited: float
    reason: str
    last_load: float

    def summary(self, settle):
        return (f'Simulator settle wait: {self.waited:.0f} s, ended: {self.reason} '
                f'(1-minute load average {self.last_load:.2f}; settled means at most '
                f'{settle.threshold:.2f} for {settle.hold:.0f} s, limit {settle.limit:.0f} s)')


def wait_until_settled(settle, read_load, now, sleep, trace):
    start = now()
    low_since = None
    while True:
        elapsed = now() - start
        load = read_load()
        trace.write(f'{elapsed:.0f} {load:.2f}\n')
        trace.flush()
        if load <= settle.threshold:
            low_since = elapsed if low_since is None else low_since
            if elapsed - low_since >= settle.hold:
                return Result(elapsed, 'settled', load)
        else:
            low_since = None
        if elapsed >= settle.limit:
            return Result(elapsed, 'limit', load)
        sleep(min(settle.interval, settle.limit - elapsed))


def boot(udid):
    listing = subprocess.run(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'],
        check=True, capture_output=True, text=True,
    )
    devices = json.loads(listing.stdout)['devices']
    device = next((device for items in devices.values() for device in items
                   if device['udid'] == udid), None)
    if device is None:
        sys.exit(f'Selected simulator {udid} is not available')
    if device['state'] == 'Shutdown':
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('udid')
    parser.add_argument('--trace', required=True,
                        help='file that receives one "seconds load" line per sample')
    parser.add_argument('--threshold', type=float, default=float(os.cpu_count() or 1))
    parser.add_argument('--hold', type=float, default=60)
    parser.add_argument('--limit', type=float, default=LIMIT_CEILING)
    parser.add_argument('--interval', type=float, default=5)
    args = parser.parse_args()
    settle = Settle(args.threshold, args.hold, args.limit, args.interval)
    boot(args.udid)
    with open(args.trace, 'w') as trace:
        trace.write(f'# booted {datetime.now(timezone.utc).isoformat(timespec="seconds")}, '
                    f'{os.cpu_count()} CPU cores\n')
        result = wait_until_settled(settle, lambda: os.getloadavg()[0],
                                    time.monotonic, time.sleep, trace)
    print(result.summary(settle))


if __name__ == '__main__':
    main()
