import unittest

from notification_roundtrip import assess_runtime


class NotificationRuntimeEvidenceTests(unittest.TestCase):
    def launches(self, first=('123', 'YES', 'YES'), cold=('456', 'YES', 'NO')):
        return '\n'.join(f'unipad[{pid}:abc] [io.unipad.tests.notifications:FirebaseRuntime] '
                         f'local_only={local} launch_override={override}'
                         for pid, local, override in [first, cold])

    def test_accepts_new_local_only_process_without_override(self):
        self.assertTrue(assess_runtime(self.launches())['cold_local_only'])

    def test_rejects_the_original_loss_of_local_only(self):
        with self.assertRaises(ValueError):
            assess_runtime(self.launches(cold=('456', 'NO', 'NO')))

    def test_rejects_reusing_the_old_process(self):
        with self.assertRaises(ValueError):
            assess_runtime(self.launches(cold=('123', 'YES', 'NO')))

    def test_rejects_relaunching_with_override(self):
        with self.assertRaises(ValueError):
            assess_runtime(self.launches(cold=('456', 'YES', 'YES')))

    def test_rejects_missing_and_duplicate_launches(self):
        for log in ['', self.launches() + '\n' + self.launches()]:
            with self.assertRaises(ValueError):
                assess_runtime(log)
