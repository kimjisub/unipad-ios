"""Verify how CI decides that a freshly booted simulator has settled."""
import io
import unittest
from unittest import mock

import simulator_settle
from simulator_settle import CpuWindow, Sample, Settle, bounded, cpu_seconds, wait_until_settled


class FakeMachine:
    """A clock that advances only when the waiter sleeps, and scripted measurements.

    `rates` is a list of (until, {name: CPU seconds per second}) for the simulator's
    processes, or (until, None) when the simulator is not found; `load` is a list of
    (until, load average). `gaps` adds extra seconds to a sleep that starts at a given time,
    like a starved sampler.
    """

    def __init__(self, rates, load=((10_000, 2.0),), gaps=None):
        self.rates = rates
        self.load = load
        self.gaps = gaps or {}
        self.time = 0.0
        self.last = 0.0
        self.used = {}

    @staticmethod
    def at(script, time):
        for until, value in script:
            if time < until:
                return value
        return script[-1][1]

    def now(self):
        return self.time

    def sleep(self, seconds):
        self.time += seconds + self.gaps.get(self.time, 0)

    def read(self):
        rates = self.at(self.rates, self.last)
        if rates is not None:
            for name, rate in rates.items():
                self.used[name] = self.used.get(name, 0.0) + rate * (self.time - self.last)
        self.last = self.time
        if rates is None:
            return Sample(None, {}, self.at(self.load, self.time))
        pids = {name: str(100 + i) for i, name in enumerate(sorted(self.used))}
        return Sample({pids[n]: cpu for n, cpu in self.used.items()},
                      {pid: n for n, pid in pids.items()}, self.at(self.load, self.time))


def wait(rates, load=((10_000, 2.0),), quiet=40.0, hold=30.0, limit=360, gaps=None,
         reason='6 min wait limit'):
    machine = FakeMachine(rates, load, gaps)
    trace = io.StringIO()
    result = wait_until_settled(
        Settle(quiet=quiet, hold=hold, limit=limit, interval=5, limit_reason=reason),
        read=machine.read, now=machine.now, sleep=machine.sleep, trace=trace,
    )
    return result, trace.getvalue()


BUSY = {'PosterBoard': 1.5, 'SpringBoard': 1.0}
CALM = {'PosterBoard': 0.0, 'SpringBoard': 0.5}


class SimulatorRuleTests(unittest.TestCase):
    def test_settles_once_the_simulator_stays_quiet_for_the_hold(self):
        # 2.5 cores for 2 minutes (75 CPU s per 30 s), then half a core (15 per 30 s).
        result, _ = wait([(120, BUSY), (10_000, CALM)])
        self.assertEqual((result.reason, result.rule), ('settled', 'simulator'))
        # The window at 140 s holds 10 busy and 20 calm seconds, 35 CPU s: quiet from then,
        # held until 170 s.
        self.assertEqual(result.waited, 170)
        self.assertAlmostEqual(result.simulator, 15.0)

    def test_a_quiet_start_settles_without_seeing_busy_first(self):
        result, _ = wait([(10_000, CALM)])
        self.assertEqual((result.reason, result.waited), ('settled', 60))

    def test_the_threshold_itself_counts_as_quiet(self):
        result, _ = wait([(10_000, {'SpringBoard': 40 / 30})])
        self.assertEqual(result.reason, 'settled')

    def test_a_short_quiet_spell_restarts_the_hold(self):
        # At 3 cores busy and half a core calm, a window is quiet with at most 10 busy
        # seconds in it: quiet 80-100 s only (20 s), then again from 170 s.
        busy = {'SpringBoard': 3.0}
        result, _ = wait([(60, busy), (90, CALM), (150, busy), (10_000, CALM)])
        self.assertEqual(result.reason, 'settled')
        self.assertEqual(result.waited, 200)

    def test_stops_at_the_limit_without_failing_and_names_it(self):
        result, _ = wait([(10_000, BUSY)], limit=200, reason='11 min after job start')
        self.assertEqual((result.reason, result.waited),
                         ('limit (11 min after job start)', 200))

    def test_a_zero_limit_ends_at_the_first_sample(self):
        result, _ = wait([(10_000, BUSY)], limit=0, reason='11 min after job start')
        self.assertEqual((result.reason, result.waited), ('limit (11 min after job start)', 0))

    def test_holds_by_real_time_when_samples_are_far_apart(self):
        # The sampler stalls for 90 s right after the simulator calms down: the next sample,
        # still quiet, is 90 real seconds later and ends the hold.
        result, _ = wait([(60, BUSY), (10_000, CALM)], gaps={95.0: 85})
        self.assertEqual(result.reason, 'settled')
        self.assertEqual(result.waited, 185)

    def test_records_the_busiest_processes_at_the_end(self):
        result, trace = wait([(10_000, BUSY)], limit=60)
        self.assertEqual([name for name, _ in result.busiest], ['PosterBoard', 'SpringBoard'])
        self.assertAlmostEqual(result.busiest[0][1], 45.0)
        self.assertIn('# busiest: PosterBoard 45.0, SpringBoard 30.0', trace)
        self.assertEqual(result.busiest_line(), 'Busiest simulator processes at the end '
                         '(CPU s per 30 s): PosterBoard 45.0, SpringBoard 30.0')

    def test_summary_names_the_wait_the_reason_and_every_measure(self):
        result, _ = wait([(10_000, BUSY)], limit=30)
        self.assertEqual(
            result.summary(Settle(quiet=40, hold=30, limit=30, interval=5)),
            'Simulator settle wait: 30 s, ended: limit (6 min wait limit) (simulator processes '
            '75.0 CPU s in the last 30 s, settled means at most 40 for 30 s; poster processes '
            '45.0; 1-minute load average 2.00)',
        )

    def test_every_sample_is_traced(self):
        _, trace = wait([(10_000, CALM)], limit=10)
        self.assertEqual(trace.splitlines()[:3], [
            '0 simulator=- poster=- simulator_processes=2 load=2.00',
            '5 simulator=- poster=- simulator_processes=2 load=2.00',
            '10 simulator=- poster=- simulator_processes=2 load=2.00',
        ])


class LoadFallbackTests(unittest.TestCase):
    def test_without_simulator_processes_waits_for_the_load_to_fall_below_its_peak(self):
        result, _ = wait([(10_000, None)],
                         load=[(60, 100.0), (120, 300.0), (150, 260.0), (10_000, 200.0)])
        self.assertEqual((result.reason, result.rule), ('settled', 'load'))
        self.assertEqual(result.waited, 180)

    def test_fallback_is_named_in_the_summary(self):
        result, _ = wait([(10_000, None)], load=[(10_000, 50.0)], limit=20)
        self.assertEqual(result.reason, 'limit (6 min wait limit)')
        self.assertIn('simulator processes not found', result.summary(
            Settle(quiet=40, hold=30, limit=20, interval=5)))
        self.assertIn('not measured', result.busiest_line())


class LimitTests(unittest.TestCase):
    def test_the_wait_limit_applies_when_the_job_deadline_is_further(self):
        self.assertEqual(bounded(360, 1000, 660, 1100), (360, '6 min wait limit'))

    def test_the_job_deadline_applies_when_it_comes_first(self):
        self.assertEqual(bounded(360, 1000, 660, 1500), (160, '11 min after job start'))

    def test_a_passed_job_deadline_leaves_no_wait(self):
        self.assertEqual(bounded(360, 1000, 660, 2000), (0, '11 min after job start'))

    def test_without_a_job_start_only_the_wait_limit_applies(self):
        self.assertEqual(bounded(360, None, 660, 2000), (360, '6 min wait limit'))

    def test_the_limit_stays_within_six_minutes(self):
        with self.assertRaises(ValueError):
            Settle(quiet=40, hold=30, limit=361, interval=5)


class MeasurementTests(unittest.TestCase):
    def test_reads_ps_cpu_times(self):
        self.assertEqual(cpu_seconds('0:01.23'), 1.23)
        self.assertEqual(cpu_seconds('12:34.50'), 754.5)
        self.assertEqual(cpu_seconds('1:02:03'), 3723)
        self.assertEqual(cpu_seconds('1-00:00:01'), 86401)

    def test_window_needs_thirty_seconds_of_samples(self):
        window = CpuWindow()
        window.add(0, {'1': 0.0})
        window.add(20, {'1': 4.0})
        self.assertIsNone(window.last())
        window.add(40, {'1': 6.0})
        self.assertAlmostEqual(window.last(), 4.5)

    def test_exited_processes_add_nothing_to_the_window(self):
        window = CpuWindow()
        window.add(0, {'1': 50.0})
        window.add(30, {})
        self.assertEqual(window.last(), 0.0)

    def test_only_the_selected_simulators_processes_are_read(self):
        runtime = '/Library/Developer/CoreSimulator/Volumes/iOS/Runtimes/iOS 27.0.simruntime/RuntimeRoot'
        listing = '\n'.join([
            '  10     1   0:01.00 launchd_sim /Users/r/Library/Developer/CoreSimulator/Devices/'
            'AAA/data/var/run/launchd_bootstrap.plist',
            '  20     1   0:01.00 launchd_sim /Users/r/Library/Developer/CoreSimulator/Devices/'
            'BBB/data/var/run/launchd_bootstrap.plist',
            f'  11    10   0:12.50 {runtime}/System/Library/CoreServices/PosterBoard.app/PosterBoard',
            f'  12    10   1:00.00 {runtime}/System/Library/ExtensionKit/Extensions/'
            'PhotosPosterProvider.appex/PhotosPosterProvider -AppleLanguages (en)',
            f'  13    10   0:03.00 {runtime}/System/Library/CoreServices/SpringBoard.app/SpringBoard',
            f'  21    20   0:09.00 {runtime}/System/Library/CoreServices/PosterBoard.app/PosterBoard',
            '  30     1   0:05.00 /System/Library/Frameworks/Contacts.framework/Support/postersyncd',
        ])
        with mock.patch.object(simulator_settle.subprocess, 'run',
                               return_value=mock.Mock(stdout=listing)):
            cpu, names = simulator_settle.read_processes('AAA')
            missing = simulator_settle.read_processes('CCC')
        self.assertEqual(cpu, {'11': 12.5, '12': 60.0, '13': 3.0})
        self.assertEqual(names, {'11': 'PosterBoard', '12': 'PhotosPosterProvider',
                                 '13': 'SpringBoard'})
        self.assertEqual(Sample(cpu, names, 1.0).poster(), {'11': 12.5, '12': 60.0})
        self.assertEqual(missing, (None, {}))


if __name__ == '__main__':
    unittest.main()
