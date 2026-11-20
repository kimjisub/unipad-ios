"""Boot the selected simulator and wait until its first-boot wallpaper work has passed.

A simulator's first boot starts PosterBoard and its wallpaper extensions minutes after it
reports booted, and while they run they keep the CI runner saturated. Tests with time
limits that run meanwhile fail on time alone. The simulator's processes are ordinary host
processes under its launchd_sim, so `ps` shows how much CPU time they used.

Settled means the poster processes (any whose name contains "poster") were seen busy, at
least `busy` CPU seconds in 30 seconds, and have since used at most `quiet` CPU seconds in
the last 30 seconds (or exited). Their work starts late, so a quiet start does not count.
When the simulator's processes cannot be found, the wait falls back to the runner's
1-minute load average staying at least 20% below its peak for 30 seconds.

The wait never fails the job: at the limit the tests start anyway. The last line printed
says how long it waited and why it ended; the trace file keeps every sample.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone

LIMIT_CEILING = 360
WINDOW = 30.0
POSTER = re.compile('poster', re.IGNORECASE)


@dataclass(frozen=True)
class Settle:
    quiet: float
    busy: float
    limit: float
    interval: float

    def __post_init__(self):
        if not 0 < self.limit <= LIMIT_CEILING:
            raise ValueError(f'limit must be within {LIMIT_CEILING} s, got {self.limit}')
        if not 0 < self.quiet < self.busy:
            raise ValueError('quiet must be positive and below busy')
        if self.interval <= 0:
            raise ValueError('interval must be positive')


@dataclass(frozen=True)
class Sample:
    """CPU seconds used so far by each poster and each simulator process, or None when the
    simulator's processes were not found, and the runner's 1-minute load average."""
    poster: dict | None
    simulator: dict | None
    load: float


class CpuWindow:
    """CPU seconds a set of processes used over the most recent 30 seconds of samples.

    Samples on a saturated runner can be far apart, so the usage between two samples is
    spread evenly over that gap. A process seen for the first time counts all its CPU time;
    one that exited drops out with what it used since the previous sample uncounted.
    """

    def __init__(self):
        self.previous = None
        self.intervals = []

    def add(self, at, cpu):
        if self.previous is not None:
            before_at, before = self.previous
            used = sum(max(0.0, t - before.get(pid, 0.0)) for pid, t in cpu.items())
            self.intervals.append((at - before_at, used))
        self.previous = (at, cpu)

    def last(self):
        """Usage per 30 s over the newest samples covering 30 s, or None until they do."""
        span = used = 0.0
        for gap, cpu in reversed(self.intervals):
            span += gap
            used += cpu
            if span >= WINDOW:
                return used * WINDOW / span
        return None


@dataclass(frozen=True)
class Result:
    waited: float
    reason: str
    rule: str
    poster: float | None
    poster_peak: float
    load: float
    load_peak: float

    def summary(self, settle):
        if self.rule == 'poster':
            measure = (f'poster processes {fmt(self.poster)} CPU s in the last 30 s, '
                       f'peak {self.poster_peak:.1f}; settled means at least {settle.busy:.1f} '
                       f'seen, then at most {settle.quiet:.1f}')
        else:
            measure = ('simulator processes not found, so: 1-minute load average at least 20% '
                       f'below its peak {self.load_peak:.2f} for 30 s')
        return (f'Simulator settle wait: {self.waited:.0f} s, ended: {self.reason} '
                f'({measure}; 1-minute load average {self.load:.2f}; '
                f'limit {settle.limit:.0f} s)')


def fmt(value):
    return '-' if value is None else f'{value:.1f}'


def wait_until_settled(settle, read, now, sleep, trace):
    start = now()
    poster, simulator = CpuWindow(), CpuWindow()
    rule = None
    poster_peak = load_peak = 0.0
    seen_busy = False
    below_peak_since = None
    while True:
        sample = read()
        elapsed = now() - start
        rule = rule or ('poster' if sample.poster is not None else 'load')
        reason = None
        load_peak = max(load_peak, sample.load)
        if rule == 'poster' and sample.poster is not None:
            poster.add(elapsed, sample.poster)
            simulator.add(elapsed, sample.simulator)
            used = poster.last()
            if used is not None:
                poster_peak = max(poster_peak, used)
                seen_busy = seen_busy or used >= settle.busy
                if seen_busy and used <= settle.quiet:
                    reason = 'settled'
        elif rule == 'load':
            if sample.load <= 0.8 * load_peak:
                below_peak_since = elapsed if below_peak_since is None else below_peak_since
                if elapsed - below_peak_since >= WINDOW:
                    reason = 'settled'
            else:
                below_peak_since = None
        trace.write(f'{elapsed:.0f} poster={fmt(poster.last())} '
                    f'poster_processes={len(sample.poster or {})} '
                    f'simulator={fmt(simulator.last())} load={sample.load:.2f}\n')
        trace.flush()
        if reason is None and elapsed >= settle.limit:
            reason = 'limit'
        if reason:
            return Result(elapsed, reason, rule, poster.last(), poster_peak,
                          sample.load, load_peak)
        sleep(min(settle.interval, settle.limit - elapsed))


def cpu_seconds(text):
    """Seconds in a `ps` cumulative CPU time such as 0:01.23, 12:34.56 or 1-02:03:04."""
    days, _, clock = text.rpartition('-')
    seconds = 0.0
    for part in clock.split(':'):
        seconds = seconds * 60 + float(part)
    return seconds + int(days or 0) * 86400


def read_processes(udid):
    """CPU seconds of the processes the simulator's launchd_sim started, split into poster
    processes and all of them; (None, None) when no launchd_sim belongs to the simulator."""
    listing = subprocess.run(['ps', '-axo', 'pid=,ppid=,time=,command='],
                             check=True, capture_output=True, text=True).stdout
    rows = [line.split(None, 3) for line in listing.splitlines()]
    rows = [row for row in rows if len(row) == 4]
    roots = {pid for pid, _, _, command in rows
             if command.startswith('launchd_sim ') and f'/Devices/{udid}/' in command}
    if not roots:
        return None, None
    poster, simulator = {}, {}
    for pid, ppid, cpu, command in rows:
        if ppid in roots:
            seconds = cpu_seconds(cpu)
            simulator[pid] = seconds
            executable = command.split(' -', 1)[0].rstrip('/').rsplit('/', 1)[-1]
            if POSTER.search(executable):
                poster[pid] = seconds
    return poster, simulator


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
    parser.add_argument('--trace', required=True, help='file that receives one line per sample')
    parser.add_argument('--quiet', type=float, default=3.0,
                        help='poster CPU seconds per 30 s at or below which they are quiet')
    parser.add_argument('--busy', type=float, default=15.0,
                        help='poster CPU seconds per 30 s at or above which they are busy')
    parser.add_argument('--limit', type=float, default=LIMIT_CEILING)
    parser.add_argument('--interval', type=float, default=5)
    args = parser.parse_args()
    settle = Settle(args.quiet, args.busy, args.limit, args.interval)
    boot(args.udid)

    def read():
        poster, simulator = read_processes(args.udid)
        return Sample(poster, simulator, os.getloadavg()[0])

    with open(args.trace, 'w') as trace:
        trace.write(f'# booted {datetime.now(timezone.utc).isoformat(timespec="seconds")}, '
                    f'{os.cpu_count()} CPU cores\n')
        result = wait_until_settled(settle, read, time.monotonic, time.sleep, trace)
    print(result.summary(settle))


if __name__ == '__main__':
    main()
