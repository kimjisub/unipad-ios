"""Boot the selected simulator and wait until its first-boot work has died down.

After a simulator's first boot its system services (PosterBoard and its wallpaper
extensions among them) keep the CI runner saturated for minutes. Tests with time limits
that run meanwhile fail on time alone. The simulator's processes are ordinary host
processes under its launchd_sim, so `ps` shows how much CPU time they used.

Settled means all the simulator's processes together used at most `quiet` CPU seconds in
the last 30 seconds, and stayed so for `hold` seconds of real time. Judgements use real
elapsed time, because samples on a saturated runner can be a minute or more apart. When the
simulator's processes cannot be found, the wait falls back to the runner's 1-minute load
average staying at least 20% below its peak for 30 seconds.

The wait ends at the earlier of its own limit and a deadline counted from the job's start,
and never fails the job: at either limit the tests start anyway. The first line printed
says how long it waited and why it ended; the second names the busiest simulator processes
at that moment. The trace file keeps every sample.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone

import simulator_background

LIMIT_CEILING = 360
WINDOW = 30.0
TOP = 5
POSTER = re.compile('poster', re.IGNORECASE)


@dataclass(frozen=True)
class Settle:
    quiet: float
    hold: float
    limit: float
    interval: float
    limit_reason: str = 'wait limit'

    def __post_init__(self):
        if not 0 <= self.limit <= LIMIT_CEILING:
            raise ValueError(f'limit must be within {LIMIT_CEILING} s, got {self.limit}')
        if self.quiet <= 0 or self.hold <= 0 or self.interval <= 0:
            raise ValueError('quiet, hold and interval must be positive')


def bounded(settle_limit, job_started, job_limit, now):
    """The wait limit and its name: the wait's own limit, or what is left of the job's
    deadline when that comes first."""
    left = max(0.0, job_started + job_limit - now) if job_started is not None else None
    if left is not None and left < settle_limit:
        return left, f'{job_limit / 60:g} min after job start'
    return settle_limit, f'{settle_limit / 60:g} min wait limit'


@dataclass(frozen=True)
class Sample:
    """CPU seconds used so far by each simulator process (None when the simulator's
    processes were not found), their names, and the runner's 1-minute load average."""
    simulator: dict | None
    names: dict
    load: float

    def poster(self):
        if self.simulator is None:
            return None
        return {pid: cpu for pid, cpu in self.simulator.items()
                if POSTER.search(self.names.get(pid, ''))}


class CpuWindow:
    """CPU seconds a set of processes used over the most recent 30 seconds of samples.

    Usage between two samples is spread evenly over the gap between them. A process seen for
    the first time counts all its CPU time; one that exited drops out with what it used
    since the previous sample uncounted.
    """

    def __init__(self):
        self.snapshots = []

    def add(self, at, cpu):
        self.snapshots.append((at, cpu))

    def usage(self):
        """Per process: CPU seconds used since the newest snapshot at least 30 s old (or the
        first), and the span that covers; None until 30 s are covered."""
        if len(self.snapshots) < 2:
            return None
        at, cpu = self.snapshots[-1]
        start = next((s for s in reversed(self.snapshots[:-1]) if at - s[0] >= WINDOW), None)
        if start is None:
            return None
        used = {pid: max(0.0, t - start[1].get(pid, 0.0)) for pid, t in cpu.items()}
        return used, at - start[0]

    def last(self):
        """Usage per 30 s over the newest samples covering 30 s, or None until they do."""
        usage = self.usage()
        if usage is None:
            return None
        used, span = usage
        return sum(used.values()) * WINDOW / span

    def busiest(self, names, count=TOP):
        usage = self.usage()
        if usage is None:
            return []
        used, span = usage
        ranked = sorted(used.items(), key=lambda item: item[1], reverse=True)[:count]
        return [(names.get(pid, pid), cpu * WINDOW / span) for pid, cpu in ranked]


@dataclass(frozen=True)
class Result:
    waited: float
    reason: str
    rule: str
    simulator: float | None
    poster: float | None
    load: float
    load_peak: float
    busiest: list = field(default_factory=list)

    def summary(self, settle):
        if self.rule == 'simulator':
            measure = (f'simulator processes {fmt(self.simulator)} CPU s in the last 30 s, '
                       f'settled means at most {settle.quiet:g} for {settle.hold:g} s; '
                       f'poster processes {fmt(self.poster)}')
        else:
            measure = ('simulator processes not found, so: 1-minute load average at least 20% '
                       f'below its peak {self.load_peak:.2f} for 30 s')
        return (f'Simulator settle wait: {self.waited:.0f} s, ended: {self.reason} '
                f'({measure}; 1-minute load average {self.load:.2f})')

    def busiest_line(self):
        listed = ', '.join(f'{name} {cpu:.1f}' for name, cpu in self.busiest) or 'not measured'
        return f'Busiest simulator processes at the end (CPU s per 30 s): {listed}'


def fmt(value):
    return '-' if value is None else f'{value:.1f}'


def wait_until_settled(settle, read, now, sleep, trace):
    start = now()
    simulator, poster = CpuWindow(), CpuWindow()
    rule = None
    load_peak = 0.0
    low_since = None
    while True:
        sample = read()
        elapsed = now() - start
        rule = rule or ('simulator' if sample.simulator is not None else 'load')
        load_peak = max(load_peak, sample.load)
        low = False
        if rule == 'simulator' and sample.simulator is not None:
            simulator.add(elapsed, sample.simulator)
            poster.add(elapsed, sample.poster())
            used = simulator.last()
            low = used is not None and used <= settle.quiet
        elif rule == 'load':
            low = sample.load <= 0.8 * load_peak
        hold = settle.hold if rule == 'simulator' else WINDOW
        low_since = (low_since if low_since is not None else elapsed) if low else None
        trace.write(f'{elapsed:.0f} simulator={fmt(simulator.last())} '
                    f'poster={fmt(poster.last())} '
                    f'simulator_processes={len(sample.simulator or {})} '
                    f'load={sample.load:.2f}\n')
        trace.flush()
        reason = None
        if low and elapsed - low_since >= hold:
            reason = 'settled'
        elif elapsed >= settle.limit:
            reason = f'limit ({settle.limit_reason})'
        if reason:
            busiest = simulator.busiest(sample.names)
            trace.write('# busiest: ' + ', '.join(f'{n} {c:.1f}' for n, c in busiest) + '\n')
            return Result(elapsed, reason, rule, simulator.last(), poster.last(),
                          sample.load, load_peak, busiest)
        sleep(min(settle.interval, settle.limit - elapsed))


def cpu_seconds(text):
    """Seconds in a `ps` cumulative CPU time such as 0:01.23, 12:34.56 or 1-02:03:04."""
    days, _, clock = text.rpartition('-')
    seconds = 0.0
    for part in clock.split(':'):
        seconds = seconds * 60 + float(part)
    return seconds + int(days or 0) * 86400


def read_processes(udid):
    """CPU seconds and executable names of the processes the simulator's launchd_sim
    started; (None, {}) when no launchd_sim belongs to the simulator."""
    listing = subprocess.run(['ps', '-axo', 'pid=,ppid=,time=,command='],
                             check=True, capture_output=True, text=True).stdout
    rows = [line.split(None, 3) for line in listing.splitlines()]
    rows = [row for row in rows if len(row) == 4]
    roots = {pid for pid, _, _, command in rows
             if command.startswith('launchd_sim ') and f'/Devices/{udid}/' in command}
    if not roots:
        return None, {}
    cpu, names = {}, {}
    for pid, ppid, used, command in rows:
        if ppid in roots:
            cpu[pid] = cpu_seconds(used)
            names[pid] = command.split(' -', 1)[0].rstrip('/').rsplit('/', 1)[-1]
    return cpu, names


def boot(udid, reduce_background=False):
    listing = subprocess.run(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '--json'],
        check=True, capture_output=True, text=True,
    )
    devices = json.loads(listing.stdout)['devices']
    device = next((device for items in devices.values() for device in items
                   if device['udid'] == udid), None)
    if device is None:
        sys.exit(f'Selected simulator {udid} is not available')
    if reduce_background:
        if device['state'] != 'Shutdown':
            raise RuntimeError('background profile requires a shut-down disposable CI simulator')
        simulator_background.prepare(udid)
    if device['state'] == 'Shutdown':
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True)
    if reduce_background:
        simulator_background.verify(udid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('udid')
    parser.add_argument('--trace', required=True, help='file that receives one line per sample')
    parser.add_argument('--quiet', type=float, default=40.0,
                        help='simulator CPU seconds per 30 s at or below which it is quiet')
    parser.add_argument('--hold', type=float, default=30.0,
                        help='real seconds the simulator must stay quiet')
    parser.add_argument('--limit', type=float, default=LIMIT_CEILING,
                        help='longest wait in seconds')
    parser.add_argument('--job-started', type=float,
                        help='Unix time the job started, for --job-limit')
    parser.add_argument('--job-limit', type=float, default=660,
                        help='seconds after the job started by which the wait ends')
    parser.add_argument('--interval', type=float, default=5)
    parser.add_argument('--reduce-background-work', action='store_true',
                        help='disable wallpaper previews and widgets on a disposable CI simulator')
    args = parser.parse_args()
    boot(args.udid, reduce_background=args.reduce_background_work)
    limit, limit_reason = bounded(args.limit, args.job_started, args.job_limit, time.time())
    settle = Settle(args.quiet, args.hold, limit, args.interval, limit_reason)

    def read():
        cpu, names = read_processes(args.udid)
        return Sample(cpu, names, os.getloadavg()[0])

    with open(args.trace, 'w') as trace:
        trace.write(f'# booted {datetime.now(timezone.utc).isoformat(timespec="seconds")}, '
                    f'{os.cpu_count()} CPU cores, wait limit {limit:.0f} s ({limit_reason})\n')
        result = wait_until_settled(settle, read, time.monotonic, time.sleep, trace)
    print(result.summary(settle))
    print(result.busiest_line())


if __name__ == '__main__':
    main()
