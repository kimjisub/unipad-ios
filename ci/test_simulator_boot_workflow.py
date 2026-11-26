"""Keep simulator startup from overlapping builds and from the tests' first minutes.

A simulator booting in the background slows every xcodebuild started meanwhile:
dependency resolution waited minutes for its first output and the Release build
took up to three times longer. So the simulator boots only after the unit tests
are built, and the tests start, without building again, once its first-boot work
has settled. The Release build and the tool tests need no simulator and run in
their own job, so they do not spend the unit test job's time.
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
        self.assertIn('--job-started "$JOB_STARTED_AT" --job-limit 660', settle)
        unit = self.step(UNIT_STEP)
        self.assertIn('xcodebuild test-without-building ', unit)
        self.assertNotIn('xcodebuild test ', unit)
        self.assertIn('-only-testing:unipadTests', unit)

    def test_background_profile_is_enabled_only_in_the_unit_test_job_and_logged(self):
        unit, release = self.jobs()
        self.assertIn('--reduce-background-work', self.step(SETTLE_STEP))
        self.assertIn('tee "$RUNNER_TEMP/simulator-background.log"', self.step(SETTLE_STEP))
        self.assertIn('${{ runner.temp }}/simulator-background.log', unit)
        self.assertNotIn('--reduce-background-work', release)

    def test_the_job_start_is_recorded_before_anything_else_runs(self):
        unit, _ = self.jobs()
        steps = unit.split('\n    steps:\n', 1)[1]
        start = steps.index('- name: ')
        first = steps[start:steps.index('\n      - name: ', start)]
        self.assertIn('echo "JOB_STARTED_AT=$(date +%s)" >> "$GITHUB_ENV"', first)

    def jobs(self):
        unit, release = self.workflow.split('\n  release-build-and-tool-tests:\n')
        return unit, release

    def test_each_job_reuses_its_own_saved_compilation_cache(self):
        cache = '${{ runner.temp }}/DerivedData/CompilationCache.noindex'
        for job, key in zip(self.jobs(), ('ios-test-compilation-cache-',
                                          'ios-release-compilation-cache-')):
            restore = job.index('uses: actions/cache/restore@')
            save = job.index('uses: actions/cache/save@')
            builds = [m.start() for m in re.finditer(r'xcodebuild (build|build-for-testing) ', job)]
            self.assertEqual(len(builds), 1)
            self.assertLess(restore, builds[0])
            self.assertLess(builds[0], save)
            for start in (restore, save):
                self.assertIn('path: ' + cache, job[start:start + 300])
            self.assertEqual(job.count('key: ' + key), 2)
            self.assertIn('restore-keys: ' + key, job)
            command = job[builds[0]:job.index('2>&1', builds[0])]
            self.assertIn('-derivedDataPath "$RUNNER_TEMP/DerivedData"', command)
            self.assertIn('COMPILATION_CACHE_ENABLE_CACHING=YES', command)
            self.assertIn('COMPILATION_CACHE_LIMIT_SIZE=', command)

    def test_release_build_and_tool_tests_run_beside_the_unit_tests(self):
        unit, release = self.jobs()
        self.assertNotIn('needs:', self.workflow)
        self.assertEqual(self.workflow.count('timeout-minutes: 30'), 2)
        self.assertNotIn('xcodebuild build ', unit)
        self.assertNotIn('unittest discover', unit)
        self.assertNotIn('open_source_licenses.py', unit)
        self.assertIn('python3 ci/run_tool_tests.py', release)
        self.assertIn('xcodebuild build ', release)
        self.assertIn('-configuration Release', release)
        self.assertIn('python3 ci/open_source_licenses.py check', release)
        self.assertNotIn('SIMULATOR_UDID', release)
        for job, artifact in zip((unit, release),
                                 ('ios-check-results', 'ios-release-build-results')):
            self.assertIn('python3 ci/firebase_fixture.py', job)
            self.assertIn('UNIPAD_WARNINGS_AS_ERRORS=YES', job)
            self.assertIn('name: ' + artifact, job)

    def test_unit_tests_build_and_run_for_the_selected_simulator(self):
        for name in (BUILD_STEP, UNIT_STEP):
            step = self.step(name)
            self.assertIn('platform=iOS Simulator,id=$SIMULATOR_UDID,arch=arm64', step)
            self.assertIn('-derivedDataPath "$RUNNER_TEMP/DerivedData"', step)
        for name in (BUILD_STEP, SETTLE_STEP, UNIT_STEP):
            self.assertIn('SIMULATOR_UDID: ${{ steps.simulator.outputs.udid }}', self.step(name))

    def test_unit_tests_reuse_resolved_packages(self):
        # Even test-without-building resolves packages unless given the build's package
        # directory. Resolving them again would add work just after the simulator settles.
        for name in (BUILD_STEP, UNIT_STEP):
            for option in ('-clonedSourcePackagesDirPath "$RUNNER_TEMP/SourcePackages"',
                           '-disableAutomaticPackageResolution'):
                with self.subTest(step=name, option=option):
                    self.assertIn(option, self.step(name))


if __name__ == '__main__':
    unittest.main()
