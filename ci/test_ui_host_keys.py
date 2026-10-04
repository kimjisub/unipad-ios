"""Execute the UI workflow command and require a working host-key bridge."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


class UIHostKeysTests(unittest.TestCase):
    def key_delivery(self, exit_code):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(dir=os.environ.get("PAPERCLIP_RUN_SCRATCH_DIR")) as directory:
            folder = Path(directory)
            fake = folder / "bin"
            fake.mkdir()
            programs = {
                "axe": f"#!/bin/sh\necho 'HID delivery result' >&2\nexit {exit_code}\n",
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
                       PAPERCLIP_RUN_SCRATCH_DIR=str(folder))
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

    def run_step(self, exit_code=0):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ios-checks.yml").read_text()
        step = workflow.split("      - name: Run all UI tests\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        scratch = os.environ.get("PAPERCLIP_RUN_SCRATCH_DIR") or os.environ.get("RUNNER_TEMP")
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            folder = Path(directory)
            fake = folder / "bin"
            fake.mkdir()
            for name, content in {
                "axe": "#!/bin/sh\nexit 0\n",
                "xcodebuild": "#!/usr/bin/env python3\n" +
                    "import json, os, pathlib, sys\n" +
                    "keys = os.environ.get('TEST_RUNNER_HOST_KEYS_DIR', '')\n" +
                    "print(json.dumps({'args': sys.argv[1:], 'keysReady': bool(keys) and pathlib.Path(keys).is_dir(), 'keysUnderScratch': bool(keys) and pathlib.Path(keys).is_relative_to(os.environ['RUNNER_TEMP']), 'fixtures': os.environ.get('TEST_RUNNER_UNIPAD_RELEASE_SUITE')}))\n" +
                    "sys.exit(" + str(exit_code) + ")\n",
            }.items():
                path = fake / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ["PATH"],
                       SIMULATOR_UDID="leased-device", RUNNER_TEMP=str(folder),
                       PAPERCLIP_RUN_SCRATCH_DIR=str(folder), TEST_RUNNER_UNIPAD_RELEASE_SUITE="1")
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script],
                                    cwd=root, env=env, capture_output=True, text=True, timeout=15)
            probe = next(json.loads(line) for line in result.stdout.splitlines() if line.startswith("{"))
            return result, probe

    def test_full_ui_command_passes_fixtures_and_host_key_bridge_to_same_device(self):
        result, probe = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(probe["keysReady"], "hardware-key UI checks must receive a live host responder directory")
        self.assertTrue(probe["keysUnderScratch"])
        self.assertEqual(probe["fixtures"], "1")
        self.assertIn("-only-testing:unipadUITests", probe["args"])
        self.assertFalse(any(arg.startswith("-skip-testing:") for arg in probe["args"]))
        self.assertIn("id=leased-device", probe["args"])

    def test_workflow_propagates_failed_ui_command(self):
        result, _ = self.run_step(exit_code=65)
        self.assertEqual(result.returncode, 65)


if __name__ == "__main__":
    unittest.main()
