"""Execute the UI test script and require a working host-key bridge."""
import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import textwrap
import time
import unittest


# Stands in for the key arrival probe build: writes the requested output file.
FAKE_PROBE_BUILD = ('if [ "$1" = --sdk ]; then\n'
                    '  while [ $# -gt 0 ]; do [ "$1" = -o ] && : > "$2"; shift; done; exit 0\n'
                    'fi\n')


ROOT = Path(__file__).resolve().parents[1]
NOT_RUN = [
    "-skip-testing:unipadUITests/VirtualLaunchpadRoundTripUITests",
    "-skip-testing:unipadUITests/VirtualMidiPlayScreenUITests",
    "-skip-testing:unipadUITests/NotificationRoundTripUITests",
    "-skip-testing:unipadUITests/LedAutoplayUITests",
    "-skip-testing:unipadUITests/StoreDownloadTests/testDownloadingAStorePackInstallsIt",
    "-skip-testing:unipadUITests/PlayInputEdgeUITests/testPointerClicksDragsAndChangesChain",
    "-skip-testing:unipadUITests/WindowControlsBackButtonTests",
]


class UIHostKeysTests(unittest.TestCase):
    def key_delivery(self, exit_code, state=0, wake_exit=0):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(dir=os.environ.get("UNIPAD_TEST_TMPDIR")) as directory:
            folder = Path(directory)
            fake = folder / "bin"
            fake.mkdir()
            programs = {
                "axe": f"#!/bin/sh\necho 'HID delivery result' >&2\nexit {exit_code}\n",
                "xcrun": "#!/bin/sh\n" + FAKE_PROBE_BUILD +
                    f"if [ \"$4\" = notifyutil ]; then echo 'com.apple.coredevice.dtuhidd.active {state}'; exit 0; fi\n" +
                    f"if [ \"$4\" = launchctl ]; then echo 'Waking HID for device='\"$3\"' target='\"$7\"; exit {wake_exit}; fi\n" +
                    "exit 99\n",
                "xcodebuild": "#!/usr/bin/env python3\n" + textwrap.dedent('''\
                    import os, pathlib, time
                    keys = pathlib.Path(os.environ['TEST_RUNNER_HOST_KEYS_DIR'])
                    (keys / 'request-probe').write_text('key 41 --duration 0.15')
                    deadline = time.monotonic() + 5
                    while not (keys / 'done-probe').exists():
                        if time.monotonic() > deadline: raise SystemExit('No host response')
                        time.sleep(0.05)
                    print('HOST_RESPONSE=' + (keys / 'done-probe').read_text().strip())
                    ''')
            }
            for name, content in programs.items():
                path = fake / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ['PATH'],
                       UNIPAD_TEST_TMPDIR=str(folder))
            result = subprocess.run(['ci/host-keys.sh', 'leased-device', str(folder / 'DD'), 'test'],
                                    cwd=root, env=env, capture_output=True, text=True, timeout=10)
            return result

    def test_failed_key_delivery_is_not_acknowledged_as_success(self):
        result = self.key_delivery(9)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('HOST_RESPONSE=failed', result.stdout)
        self.assertIn('HID delivery result', result.stdout + result.stderr)

    def test_successful_key_delivery_is_acknowledged_and_logged(self):
        result = self.key_delivery(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('HOST_RESPONSE=successful', result.stdout)
        self.assertIn('HID delivery result', result.stdout + result.stderr)

    def test_active_new_input_service_is_woken_on_the_same_device_before_delivery(self):
        result = self.key_delivery(0, state=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('HOST_RESPONSE=successful', result.stdout)
        self.assertIn('Waking HID for device=leased-device target=user/', result.stdout)
        self.assertLess(result.stdout.index('Waking HID'), result.stdout.index('HID delivery result'))

    def test_failed_service_wake_never_sends_a_key_or_reports_success(self):
        result = self.key_delivery(0, state=1, wake_exit=7)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('HOST_RESPONSE=failed', result.stdout)
        self.assertNotIn('HID delivery result', result.stdout)

    def test_unknown_input_state_is_rejected_without_sending_a_key(self):
        result = self.key_delivery(0, state=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('HOST_RESPONSE=failed', result.stdout)
        self.assertNotIn('HID delivery result', result.stdout)

    def test_responder_stops_when_the_runner_is_killed(self):
        self.kill_runner(probe_build=FAKE_PROBE_BUILD)

    def test_runner_killed_while_building_the_probe_leaves_nothing_behind(self):
        self.kill_runner(probe_build='[ "$1" = --sdk ] && exec sleep 30\n')

    def test_runner_killed_right_after_creating_its_folder_leaves_nothing_behind(self):
        # The folder exists but mktemp has not returned, so the script has not
        # reached anything that follows it.
        self.kill_runner(probe_build=FAKE_PROBE_BUILD,
                         programs={"mktemp": '#!/bin/sh\n/usr/bin/mktemp "$@"\nexec sleep 30\n'})

    def kill_runner(self, probe_build, programs=None):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(dir=os.environ.get("UNIPAD_TEST_TMPDIR")) as directory:
            folder = Path(directory)
            fake = folder / "bin"
            fake.mkdir()
            for name, content in {"xcodebuild": "#!/bin/sh\nexec sleep 30\n",
                                  "xcrun": "#!/bin/sh\n" + probe_build + "exit 99\n", **(programs or {})}.items():
                path = fake / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"],
                       UNIPAD_TEST_TMPDIR=str(folder))
            runner = subprocess.Popen(["ci/host-keys.sh", "leased-device", str(folder / "DD"), "test"],
                                      cwd=root, env=env, start_new_session=True,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            marker = f"ci/host-keys.sh leased-device {folder}"
            try:
                deadline = time.monotonic() + 5
                while not list(folder.glob("unipad-host-keys.*")):
                    self.assertLess(time.monotonic(), deadline, "the responder directory was never created")
                    time.sleep(0.05)
                runner.kill()
                runner.wait()
                deadline = time.monotonic() + 3
                while subprocess.run(["pgrep", "-f", marker], capture_output=True).returncode == 0:
                    self.assertLess(time.monotonic(), deadline, "the key responder outlived its killed runner")
                    time.sleep(0.1)
                self.assertEqual(list(folder.glob("unipad-host-keys.*")), [])
            finally:
                try:
                    os.killpg(runner.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def run_script(self, exit_code=0, summary=None, args=(), container=None, inspect=None, environment=None):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(dir=os.environ.get("UNIPAD_TEST_TMPDIR")) as directory:
            folder = Path(directory)
            if container is not None:
                container = container(folder)
            fake = folder / "bin"
            fake.mkdir()
            if summary is None:
                summary = dict(totalTestCount=3, passedTests=3, failedTests=0, skippedTests=0)
            for name, content in {
                "axe": "#!/bin/sh\nexit 0\n",
                "xcodebuild": "#!/usr/bin/env python3\n" +
                    "import json, os, pathlib, sys\n" +
                    "keys = os.environ.get('TEST_RUNNER_HOST_KEYS_DIR', '')\n" +
                    "print(json.dumps({'args': sys.argv[1:], 'keysReady': bool(keys) and pathlib.Path(keys).is_dir(), " +
                    "'probeReady': bool(keys) and (pathlib.Path(keys) / 'key-arrival-probe.dylib').is_file(), " +
                    "'fixtures': os.environ.get('TEST_RUNNER_UNIPAD_RELEASE_SUITE')}))\n" +
                    "sys.exit(" + str(exit_code) + ")\n",
                "xcrun": "#!/bin/sh\n" + FAKE_PROBE_BUILD +
                    ("[ \"$1 $2 $3 $4 $5\" = 'simctl get_app_container leased-device kim.jisub.unipad data' ]"
                     f" && echo '{container}' && exit 0\n" if container else "") +
                    "[ \"$1 $2 $3 $4\" = 'xcresulttool get test-results summary' ] || exit 99\n" +
                    f"echo '{json.dumps(summary)}'\n",
            }.items():
                path = fake / name
                path.write_text(content)
                path.chmod(0o755)
            output = folder / "out"
            env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"],
                       UNIPAD_TEST_TMPDIR=str(folder), UNIPAD_UI_TEST_OUTPUT=str(output), **(environment or {}))
            result = subprocess.run(["ci/ui-tests.sh", "leased-device", *args],
                                    cwd=root, env=env, capture_output=True, text=True, timeout=15)
            log = (output / "ui-tests.log").read_text()
            probe = next(json.loads(line) for line in log.splitlines() if line.startswith("{"))
            if inspect:
                inspect(container)
            return result, probe

    def test_leftover_test_libraries_are_cleared_and_user_files_kept(self):
        def make_container(folder):
            documents = folder / "container" / "Documents"
            locked = documents / "ReleaseTests" / "old-token" / "UniPack" / "Deletion"
            locked.mkdir(parents=True)
            (locked / "info").write_text("title=UI Test Pack")
            (documents / "00-ReleaseTestImports").mkdir()
            (documents / "00-ReleaseTestImports" / "ReleaseFixture-old.zip").write_text("zip")
            (documents / "UniPack" / "Mine").mkdir(parents=True)
            subprocess.run(["chflags", "-R", "uchg", str(documents / "ReleaseTests")], check=True)
            return documents.parent

        def check(container):
            documents = container / "Documents"
            leftovers = [name for name in ("ReleaseTests", "00-ReleaseTestImports") if (documents / name).exists()]
            if leftovers:
                subprocess.run(["chflags", "-R", "nouchg", str(documents)], check=False)
            self.assertEqual(leftovers, [])
            self.assertTrue((documents / "UniPack" / "Mine").is_dir(), "the user's own packs must stay")

        result, _ = self.run_script(container=make_container, inspect=check)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_full_ui_command_passes_fixtures_and_host_key_bridge_to_same_device(self):
        result, probe = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(probe["keysReady"], "hardware-key UI checks must receive a live host responder directory")
        self.assertTrue(probe["probeReady"], "hardware-key UI checks must receive the key arrival probe")
        self.assertEqual(probe["fixtures"], "1")
        self.assertIn("-only-testing:unipadUITests", probe["args"])
        self.assertIn("UNIPAD_WARNINGS_AS_ERRORS=YES", probe["args"])
        self.assertEqual([arg for arg in probe["args"] if arg.startswith("-skip-testing:")], NOT_RUN)
        self.assertIn("id=leased-device", probe["args"])
        self.assertEqual(result.stdout.strip().splitlines()[-1],
                         "UI tests: 3 passed, 0 failed, 0 skipped; 3 total; exit 0")

    def test_every_check_left_out_still_exists_and_has_a_reason(self):
        script = (ROOT / "ci/ui-tests.sh").read_text().splitlines()
        tests = ROOT / "unipadUITests"
        for entry in NOT_RUN:
            index = next(i for i, line in enumerate(script) if line.strip() == entry)
            self.assertTrue(script[index - 1].strip().startswith("#"), f"{entry} needs a reason above it")
            parts = entry.split("/")[1:]
            source = (tests / f"{parts[0]}.swift").read_text()
            self.assertIn(f"class {parts[0]}", source)
            if len(parts) > 1:
                self.assertIn(f"func {parts[1]}(", source)

    def test_selected_classes_replace_the_whole_target(self):
        result, probe = self.run_script(args=["-only-testing:unipadUITests/PackWarningUITests"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-only-testing:unipadUITests/PackWarningUITests", probe["args"])
        self.assertNotIn("-only-testing:unipadUITests", probe["args"])

    def test_full_ui_command_builds_debug_without_extra_conditions(self):
        result, probe = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        configuration = probe["args"].index("-configuration")
        self.assertEqual(probe["args"][configuration + 1], "Debug")
        self.assertFalse([arg for arg in probe["args"] if arg.startswith(("UNIPAD_TEST_CONDITIONS=", "ENABLE_TESTABILITY="))])

    def test_release_feature_plan_runs_on_a_release_build_with_fixtures(self):
        result, probe = self.run_script(args=["-testPlan", "ReleaseFeatures"],
                                        environment={"UNIPAD_UI_TEST_CONFIGURATION": "Release"})
        self.assertEqual(result.returncode, 0, result.stderr)
        args = probe["args"]
        self.assertEqual(args[args.index("-configuration") + 1], "Release")
        self.assertEqual(args[args.index("-testPlan") + 1], "ReleaseFeatures")
        self.assertNotIn("-only-testing:unipadUITests", args)
        self.assertIn("UNIPAD_TEST_CONDITIONS=UNIPAD_RELEASE_TESTS", args)
        self.assertIn("ENABLE_TESTABILITY=YES", args)
        self.assertEqual(probe["fixtures"], "1")

    def test_skipped_test_fails_the_run_even_when_xcodebuild_succeeds(self):
        result, _ = self.run_script(summary=dict(totalTestCount=3, passedTests=2, failedTests=0, skippedTests=1))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip().splitlines()[-1],
                         "UI tests: 2 passed, 0 failed, 1 skipped; 3 total; exit 1")

    def test_failed_ui_command_keeps_its_exit_code(self):
        result, _ = self.run_script(exit_code=65,
                                    summary=dict(totalTestCount=3, passedTests=2, failedTests=1, skippedTests=0))
        self.assertEqual(result.returncode, 65)
        self.assertEqual(result.stdout.strip().splitlines()[-1],
                         "UI tests: 2 passed, 1 failed, 0 skipped; 3 total; exit 65")


if __name__ == "__main__":
    unittest.main()
