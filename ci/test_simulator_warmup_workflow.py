"""Keep simulator startup off the unit-test launch path."""
from pathlib import Path
import unittest


class SimulatorWarmupWorkflowTests(unittest.TestCase):
    def test_boot_overlaps_builds_and_readiness_is_checked_before_tests(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/ios-checks.yml').read_text()
        start = 'python3 ci/simulator_startup.py start "$udid"'
        ready = 'python3 ci/simulator_startup.py wait "$SIMULATOR_UDID"'
        self.assertIn(start, workflow, 'the selected simulator is still shut down until unit tests start')
        self.assertIn(ready, workflow, 'unit tests must wait for the selected simulator to finish booting')
        self.assertLess(workflow.index(start), workflow.index('- name: Resolve pinned dependencies'))
        self.assertLess(workflow.index('- name: Run unit tests without UI tests'), workflow.index(ready))
        self.assertLess(workflow.index(ready), workflow.index('xcodebuild test -quiet'))


if __name__ == '__main__':
    unittest.main()
