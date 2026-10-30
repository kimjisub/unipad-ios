"""Verify that CI picks an iPhone simulator the selected Xcode can run."""
import unittest

from pick_simulator import pick

PREFIX = 'com.apple.CoreSimulator.SimRuntime'


def iphone(name, udid, available=True):
    return {'name': name, 'udid': udid, 'isAvailable': available}


class PickSimulatorTests(unittest.TestCase):
    def test_skips_runtimes_newer_than_the_sdk(self):
        devices = {
            f'{PREFIX}.iOS-27-2': [iphone('iPhone 17', 'too-new')],
            f'{PREFIX}.iOS-27-1': [iphone('iPhone 17', 'match')],
        }
        self.assertEqual(pick(devices, '27.1', ['iPhone 17'])['udid'], 'match')

    def test_falls_back_to_the_newest_older_runtime(self):
        devices = {
            f'{PREFIX}.iOS-26-4': [iphone('iPhone 17', 'old')],
            f'{PREFIX}.iOS-27-0': [iphone('iPhone 17', 'newest-supported')],
            f'{PREFIX}.iOS-27-2': [iphone('iPhone 17', 'too-new')],
        }
        self.assertEqual(pick(devices, '27.1', ['iPhone 17'])['udid'], 'newest-supported')

    def test_compares_versions_numerically(self):
        devices = {
            f'{PREFIX}.iOS-27-9': [iphone('iPhone 17', 'nine')],
            f'{PREFIX}.iOS-27-10': [iphone('iPhone 17', 'ten')],
        }
        self.assertEqual(pick(devices, '27.10', ['iPhone 17'])['udid'], 'ten')

    def test_without_the_preferred_model_picks_the_first_by_name(self):
        devices = {f'{PREFIX}.iOS-27-1': [
            iphone('iPhone Air', 'air'), iphone('iPhone 17 Pro', 'pro'), iphone('iPhone 17', 'gone', False),
        ]}
        self.assertEqual(pick(devices, '27.1', ['iPhone 17'])['udid'], 'pro')

    def test_prefers_the_model_on_an_older_runtime_over_other_models_on_a_newer_one(self):
        devices = {
            f'{PREFIX}.iOS-27-1': [iphone('iPhone Duo', 'duo')],
            f'{PREFIX}.iOS-27-0': [iphone('iPhone 17', 'seventeen')],
        }
        self.assertEqual(pick(devices, '27.1', ['iPhone 17'])['udid'], 'seventeen')

    def test_takes_preferred_models_in_order(self):
        devices = {
            f'{PREFIX}.iOS-27-1': [iphone('iPhone 17', 'seventeen')],
            f'{PREFIX}.iOS-27-0': [iphone('iPhone 17 Pro', 'pro')],
        }
        self.assertEqual(pick(devices, '27.1', ['iPhone 17 Pro', 'iPhone 17'])['udid'], 'pro')
        self.assertEqual(pick(devices, '27.1', ['iPhone 16', 'iPhone 17'])['udid'], 'seventeen')

    def test_ignores_patch_versions_of_runtimes(self):
        devices = {f'{PREFIX}.iOS-27-1-1': [iphone('iPhone 17', 'patch')]}
        self.assertEqual(pick(devices, '27.1', ['iPhone 17'])['udid'], 'patch')

    def test_ignores_ipads_watches_and_unavailable_devices(self):
        devices = {
            f'{PREFIX}.iOS-27-1': [{'name': 'iPad Air 11-inch (M4)', 'udid': 'ipad', 'isAvailable': True}],
            f'{PREFIX}.watchOS-12-0': [iphone('iPhone 17', 'watch-runtime')],
        }
        self.assertIsNone(pick(devices, '27.1', ['iPhone 17']))


if __name__ == '__main__':
    unittest.main()
