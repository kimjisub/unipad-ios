"""Keep simulator startup from overlapping builds and from the tests' first minutes.

A simulator booting in the background slows every xcodebuild started meanwhile:
dependency resolution waited minutes for its first output and the Release build
took up to three times longer. So the simulator boots only after the unit tests
are built, and the tests start, without building again, once its first-boot work
has settled.
"""
from pathlib import Path
import re
import unittest

WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/ios-checks.yml'
BUILD_STEP = '- name: Build unit tests'
SETTLE_STEP = '- name: Boot the simulator and wait for it to settle'
UNIT_STEP = '- name: Run unit tests without UI tests'
BOOT = re.compile(r'simctl\s+boot|simulator_settle\.py|xcodebuild test ')


class SimulatorBootWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW.read_text()

    def step(self, name):
        start = self.workflow.index(name)
        end = self.workflow.find('\n      - name: ', start + 1)
        return self.workflow[start:end if end != -1 else None]

    def test_nothing_boots_a_simulator_until_the_unit_tests_are_built(self):
        before_settle = self.workflow[:self.workflow.index(SETTLE_STEP)]
        self.assertIsNone(BOOT.search(before_settle),
                          'a simulator starts while dependencies resolve or the app builds')
        self.assertLess(self.workflow.index(BUILD_STEP), self.workflow.index(SETTLE_STEP))
        self.assertIn('xcodebuild build-for-testing ', self.step(BUILD_STEP))

    def test_unit_tests_start_after_the_settle_wait_without_building(self):
        self.assertLess(self.workflow.index(SETTLE_STEP), self.workflow.index(UNIT_STEP))
        settle = self.step(SETTLE_STEP)
        self.assertIn('python3 ci/simulator_settle.py "$SIMULATOR_UDID"', settle)
        self.assertNotIn('continue-on-error', settle)
        unit = self.step(UNIT_STEP)
        self.assertIn('xcodebuild test-without-building ', unit)
        self.assertNotIn('xcodebuild test ', unit)
        self.assertIn('-only-testing:unipadTests', unit)

    def test_both_builds_reuse_the_saved_compilation_cache(self):
        cache = '${{ runner.temp }}/DerivedData/CompilationCache.noindex'
        restore = self.workflow.index('uses: actions/cache/restore@')
        save = self.workflow.index('uses: actions/cache/save@')
        builds = [m.start() for m in re.finditer(r'xcodebuild (build|build-for-testing) ', self.workflow)]
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

    def test_unit_tests_build_and_run_for_the_selected_simulator(self):
        for name in (BUILD_STEP, UNIT_STEP):
            step = self.step(name)
            self.assertIn('platform=iOS Simulator,id=$SIMULATOR_UDID,arch=arm64', step)
            self.assertIn('-derivedDataPath "$RUNNER_TEMP/DerivedData"', step)
        for name in (BUILD_STEP, SETTLE_STEP, UNIT_STEP):
            self.assertIn('SIMULATOR_UDID: ${{ steps.simulator.outputs.udid }}', self.step(name))


if __name__ == '__main__':
    unittest.main()
