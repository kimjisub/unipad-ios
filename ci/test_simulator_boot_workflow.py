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

    def test_both_builds_reuse_the_saved_compilation_cache(self):
        cache = '${{ runner.temp }}/DerivedData/CompilationCache.noindex'
        restore = self.workflow.index('uses: actions/cache/restore@')
        save = self.workflow.index('uses: actions/cache/save@')
        builds = [m.start() for m in re.finditer(r'xcodebuild (build|test) ', self.workflow)]
        self.assertEqual(len(builds), 2)
        self.assertLess(restore, builds[0])
        self.assertLess(builds[1], save)
        for start in (restore, save):
            self.assertIn('path: ' + cache, self.workflow[start:start + 300])
        for start in builds:
            command = self.workflow[start:self.workflow.index('2>&1', start)]
            self.assertIn('-derivedDataPath "$RUNNER_TEMP/DerivedData"', command)
            self.assertIn('COMPILATION_CACHE_ENABLE_CACHING=YES', command)
            self.assertIn('COMPILATION_CACHE_LIMIT_SIZE=', command)

    def test_unit_tests_run_on_the_selected_simulator(self):
        unit_step = self.workflow[self.workflow.index(UNIT_STEP):]
        self.assertIn('platform=iOS Simulator,id=$SIMULATOR_UDID,arch=arm64', unit_step)
        self.assertIn('SIMULATOR_UDID: ${{ steps.simulator.outputs.udid }}', unit_step)


if __name__ == '__main__':
    unittest.main()
