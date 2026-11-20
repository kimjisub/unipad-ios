"""Verify how CI decides that a freshly booted simulator has settled."""
import io
import unittest
from unittest import mock

import simulator_settle
from simulator_settle import CpuWindow, Sample, Settle, cpu_seconds, wait_until_settled


class FakeMachine:
    """A clock that advances only when the waiter sleeps, and scripted measurements.

    `poster` and `load` are lists of (until, value): poster values are CPU seconds the poster
    processes use per second until that time, or None when the simulator is not found.
    """

    def __init__(self, poster, load=((10_000, 2.0),), gaps=None):
        self.poster = poster
        self.load = load
        self.gaps = gaps or {}
        self.time = 0.0
        self.used = 0.0
        self.last = 0.0

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
        rate = self.at(self.poster, self.last)
        if rate is not None:
            self.used += rate * (self.time - self.last)
        self.last = self.time
        processes = None if rate is None else {'101': self.used}
        return Sample(processes, None if rate is None else {'100': 1.0, **processes},
                      self.at(self.load, self.time))


def wait(poster, load=((10_000, 2.0),), quiet=3.0, busy=15.0, limit=360, gaps=None):
    machine = FakeMachine(poster, load, gaps)
    trace = io.StringIO()
    result = wait_until_settled(
        Settle(quiet=quiet, busy=busy, limit=limit, interval=5),
        read=machine.read, now=machine.now, sleep=machine.sleep, trace=trace,
    )
    return result, trace.getvalue()


class PosterRuleTests(unittest.TestCase):
    def test_settles_once_the_busy_poster_processes_go_quiet(self):
        # Quiet for 2 minutes, a full core for 2 minutes, then nearly idle.
        result, _ = wait([(120, 0.0), (240, 1.0), (10_000, 0.01)])
        self.assertEqual((result.reason, result.rule), ('settled', 'poster'))
        self.assertEqual(result.waited, 270)
        self.assertEqual(result.poster_peak, 30.0)

    def test_a_quiet_start_is_not_settled(self):
        result, _ = wait([(10_000, 0.0)], limit=200)
        self.assertEqual((result.reason, result.waited), ('limit', 200))

    def test_activity_below_busy_does_not_arm_the_rule(self):
        result, _ = wait([(100, 0.0), (130, 0.4), (10_000, 0.0)], limit=300)
        self.assertEqual((result.reason, result.waited), ('limit', 300))

    def test_settles_thirty_seconds_after_the_busy_processes_go_idle(self):
        result, _ = wait([(60, 1.0), (10_000, 0.0)])
        self.assertEqual(result.reason, 'settled')
        self.assertEqual(result.waited, 90)

    def test_stops_at_the_limit_without_failing_while_still_busy(self):
        result, _ = wait([(10_000, 1.0)], limit=360)
        self.assertEqual((result.reason, result.waited), ('limit', 360))

    def test_a_late_sample_spreads_its_usage_over_the_gap(self):
        # The runner stalls the sampler for 60 s; the busy minute still arms the rule
        # and the quiet window after it settles.
        result, _ = wait([(60, 1.0), (10_000, 0.0)], gaps={20.0: 55})
        self.assertEqual(result.reason, 'settled')

    def test_summary_names_the_wait_the_reason_and_both_measures(self):
        result, _ = wait([(10_000, 1.0)], limit=30)
        self.assertEqual(
            result.summary(Settle(quiet=3.0, busy=15.0, limit=30, interval=5)),
            'Simulator settle wait: 30 s, ended: limit (poster processes 30.0 CPU s in the '
            'last 30 s, peak 30.0; settled means at least 15.0 seen, then at most 3.0; '
            '1-minute load average 2.00; limit 30 s)',
        )

    def test_every_sample_is_traced(self):
        _, trace = wait([(10_000, 0.0)], limit=10)
        self.assertEqual(trace.splitlines(), [
            '0 poster=- poster_processes=1 simulator=- load=2.00',
            '5 poster=- poster_processes=1 simulator=- load=2.00',
            '10 poster=- poster_processes=1 simulator=- load=2.00',
        ])


class LoadFallbackTests(unittest.TestCase):
    def test_without_simulator_processes_waits_for_the_load_to_fall_below_its_peak(self):
        result, _ = wait([(10_000, None)],
                         load=[(60, 100.0), (120, 300.0), (150, 260.0), (10_000, 200.0)])
        self.assertEqual((result.reason, result.rule), ('settled', 'load'))
        self.assertEqual(result.waited, 180)

    def test_fallback_is_named_in_the_summary(self):
        result, _ = wait([(10_000, None)], load=[(10_000, 50.0)], limit=20)
        self.assertEqual(result.reason, 'limit')
        self.assertIn('simulator processes not found', result.summary(
            Settle(quiet=3.0, busy=15.0, limit=20, interval=5)))


class MeasurementTests(unittest.TestCase):
    def test_exited_processes_add_nothing_to_the_window(self):
        window = CpuWindow()
        window.add(0, {'1': 50.0})
        window.add(30, {})
        self.assertEqual(window.last(), 0.0)

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

    def test_only_the_selected_simulators_poster_processes_are_read(self):
        runtime = '/Library/Developer/CoreSimulator/Volumes/iOS/RuntimeRoot'
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
            poster, simulator = simulator_settle.read_processes('AAA')
            missing = simulator_settle.read_processes('CCC')
        self.assertEqual(poster, {'11': 12.5, '12': 60.0})
        self.assertEqual(simulator, {'11': 12.5, '12': 60.0, '13': 3.0})
        self.assertEqual(missing, (None, None))

    def test_the_limit_stays_within_six_minutes(self):
        with self.assertRaises(ValueError):
            Settle(quiet=3.0, busy=15.0, limit=361, interval=5)


if __name__ == '__main__':
    unittest.main()
