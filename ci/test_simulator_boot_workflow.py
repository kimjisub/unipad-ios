"""Keep simulator startup from overlapping dependency resolution and builds.

A simulator booting in the background slows every xcodebuild started meanwhile:
dependency resolution waited minutes for its first output and the Release build
took up to three times longer. The unit test run boots its own destination.
"""
from pathlib import Path
import re
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/ios-checks.yml'
UNIT_STEP = '- name: Run unit tests without UI tests'
BOOT = re.compile(r'simctl\s+boot|simulator_startup\.py')


class SimulatorBootWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW.read_text()

    def test_nothing_boots_a_simulator_before_the_unit_test_step(self):
        before_tests = self.workflow[:self.workflow.index(UNIT_STEP)]
        self.assertIsNone(BOOT.search(before_tests),
                          'a simulator starts while dependencies resolve or the app builds')

    def test_unit_tests_run_on_the_selected_simulator(self):
        unit_step = self.workflow[self.workflow.index(UNIT_STEP):]
        self.assertIn('platform=iOS Simulator,id=$SIMULATOR_UDID,arch=arm64', unit_step)
        self.assertIn('SIMULATOR_UDID: ${{ steps.simulator.outputs.udid }}', unit_step)


if __name__ == '__main__':
    unittest.main()
