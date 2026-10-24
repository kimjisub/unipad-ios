"""Keep related MIDI suites in one live virtual-device session."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MidiInputRunnerTests(unittest.TestCase):
    def run_suites(self, selections=(), exit_code=0):
        with tempfile.TemporaryDirectory(dir=os.environ.get('UNIPAD_TEST_TMPDIR')) as directory:
            folder = Path(directory)
            fake = folder / 'bin'
            fake.mkdir()
            programs = {
                'xcrun': '''#!/usr/bin/env python3
import os, pathlib, sys, time
if sys.argv[1] == '--sdk':
    pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).touch()
else:
    with open(os.environ['SPAWNS'], 'a') as f: f.write('spawn\\n')
    print('ready: pid=%d' % os.getpid(), flush=True)
    time.sleep(15)
''',
                'codesign': '#!/bin/sh\nexit 0\n',
                'xcodebuild': '''#!/usr/bin/env python3
import json, os, pathlib, sys
pathlib.Path(os.environ['ARGS']).write_text(json.dumps(sys.argv[1:]))
assert pathlib.Path(os.environ['TEST_RUNNER_UNIPAD_VIRTUAL_MIDI_DIR']).is_dir()
sys.exit(int(os.environ['BUILD_EXIT']))
''',
            }
            for name, content in programs.items():
                path = fake / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ['PATH'],
                       SPAWNS=str(folder / 'spawns'), ARGS=str(folder / 'args'), BUILD_EXIT=str(exit_code))
            result = subprocess.run(['zsh', 'ci/midi-input-tests.sh', 'leased-device',
                                     str(folder / 'dd'), str(folder / 'results'), *selections],
                                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=10)
            args = json.loads((folder / 'args').read_text()) if (folder / 'args').exists() else []
            spawns = (folder / 'spawns').read_text().splitlines() if (folder / 'spawns').exists() else []
            return result, args, spawns

    def test_input_and_screen_suites_share_one_client_lifetime(self):
        suites = ['unipadTests/PlayUsageRecordTests/MidiInputPathTests',
                  'unipadTests/PlayUsageRecordTests/MidiDeviceSelectionTests',
                  'unipadUITests/VirtualMidiPlayScreenUITests']
        result, args, spawns = self.run_suites(suites)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([arg for arg in args if arg.startswith('-only-testing:')],
                         ['-only-testing:' + suite for suite in suites])
        self.assertEqual(spawns, ['spawn'])
        self.assertIn('id=leased-device', args)

    def test_combined_suite_failure_stays_failed(self):
        result, _, spawns = self.run_suites(['unipadTests/First', 'unipadUITests/Second'], 65)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertEqual(spawns, ['spawn'])

    def test_default_suites_still_share_one_client(self):
        result, args, spawns = self.run_suites()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len([arg for arg in args if arg.startswith('-only-testing:')]), 2)
        self.assertEqual(spawns, ['spawn'])
