"""Verify how CI decides that a freshly booted simulator has settled."""
import io
import unittest

from simulator_settle import Settle, wait_until_settled


class FakeMachine:
    """A clock that advances only when the waiter sleeps, and a scripted load average."""

    def __init__(self, loads):
        self.loads = loads
        self.time = 0.0

    def now(self):
        return self.time

    def sleep(self, seconds):
        self.time += seconds

    def load(self):
        for until, value in self.loads:
            if self.time < until:
                return value
        return self.loads[-1][1]


def wait(loads, threshold=3.0, hold=60, limit=480, interval=5):
    machine = FakeMachine(loads)
    trace = io.StringIO()
    result = wait_until_settled(
        Settle(threshold=threshold, hold=hold, limit=limit, interval=interval),
        read_load=machine.load, now=machine.now, sleep=machine.sleep, trace=trace,
    )
    return result, trace.getvalue()


class SimulatorSettleTests(unittest.TestCase):
    def test_settles_once_the_load_stays_low_for_the_whole_hold(self):
        result, _ = wait([(200, 6.0), (10_000, 1.5)])
        self.assertEqual(result.reason, 'settled')
        self.assertEqual(result.waited, 260)

    def test_a_short_dip_does_not_count_as_settled(self):
        result, _ = wait([(100, 6.0), (130, 1.0), (300, 7.0), (10_000, 2.0)])
        self.assertEqual(result.reason, 'settled')
        self.assertEqual(result.waited, 360)

    def test_the_threshold_itself_counts_as_low(self):
        result, _ = wait([(10_000, 3.0)])
        self.assertEqual((result.reason, result.waited), ('settled', 60))

    def test_stops_at_the_limit_without_failing(self):
        result, _ = wait([(10_000, 9.0)], limit=480)
        self.assertEqual((result.reason, result.waited), ('limit', 480))

    def test_a_hold_that_would_end_past_the_limit_stops_at_the_limit(self):
        result, _ = wait([(450, 9.0), (10_000, 1.0)], limit=480)
        self.assertEqual((result.reason, result.waited), ('limit', 480))

    def test_every_sample_is_traced(self):
        _, trace = wait([(10_000, 1.25)], hold=10, interval=5)
        self.assertEqual(trace.splitlines(), ['0 1.25', '5 1.25', '10 1.25'])

    def test_summary_names_the_wait_and_why_it_ended(self):
        result, _ = wait([(10_000, 9.0)], limit=30)
        self.assertEqual(
            result.summary(Settle(threshold=3.0, hold=60, limit=30, interval=5)),
            'Simulator settle wait: 30 s, ended: limit '
            '(1-minute load average 9.00; settled means at most 3.00 for 60 s, limit 30 s)',
        )

    def test_the_limit_stays_within_eight_minutes(self):
        with self.assertRaises(ValueError):
            Settle(threshold=3.0, hold=60, limit=481, interval=5)


if __name__ == '__main__':
    unittest.main()
