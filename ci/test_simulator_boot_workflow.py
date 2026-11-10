"""Boot the test simulator early, but never while xcodebuild runs.

Unit tests on a simulator booted just before them ran far slower, so it boots
first. A simulator still booting in the background made every xcodebuild started
meanwhile wait minutes to begin, so the job waits for the boot to finish.
"""
from pathlib import Path
import re
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/ios-checks.yml'
WAITING_BOOT = 'xcrun simctl bootstatus "$SIMULATOR_UDID" -b'


class SimulatorBootWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW.read_text()

    def test_selected_simulator_finishes_booting_before_any_build_work(self):
        self.assertIn(WAITING_BOOT, self.workflow, 'the selected simulator is not booted before the builds')
        boot = self.workflow.index(WAITING_BOOT)
        self.assertLess(self.workflow.index('id: simulator'), boot)
        self.assertLess(boot, self.workflow.index('xcodebuild -resolvePackageDependencies'))
        self.assertIn('SIMULATOR_UDID: ${{ steps.simulator.outputs.udid }}',
                      self.workflow[self.workflow.rindex('- name:', 0, boot):boot])

    def test_nothing_boots_a_simulator_without_waiting_for_it(self):
        self.assertIsNone(re.search(r'simctl\s+boot\b', self.workflow),
                          'a simulator boots in the background while xcodebuild runs')

    def test_unit_tests_run_on_the_booted_simulator(self):
        unit_step = self.workflow[self.workflow.index('- name: Run unit tests without UI tests'):]
        self.assertIn('platform=iOS Simulator,id=$SIMULATOR_UDID,arch=arm64', unit_step)
        self.assertIn('SIMULATOR_UDID: ${{ steps.simulator.outputs.udid }}', unit_step)


if __name__ == '__main__':
    unittest.main()
