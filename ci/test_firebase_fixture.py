"""Verify that CI configuration is standalone, fake, and local-only."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


class FirebaseFixtureTests(unittest.TestCase):
    def test_generates_fake_configuration_without_reading_existing_values(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('PAPERCLIP_RUN_SCRATCH_DIR')) as directory:
            output = Path(directory) / 'GoogleService-Info.plist'
            output.write_text('not a plist: must be replaced without reading')
            subprocess.run(
                [sys.executable, str(Path(__file__).with_name('firebase_fixture.py')), str(output)],
                check=True,
            )
            with output.open('rb') as file:
                config = plistlib.load(file)
            self.assertEqual(config['API_KEY'], 'FAKE-CI-API-KEY-NOT-A-CREDENTIAL')
            self.assertEqual(config['PROJECT_ID'], 'fake-unipad-ci')
            self.assertEqual(config['GOOGLE_APP_ID'], '1:000000000000:ios:0000000000000000')
            self.assertEqual(config['BUNDLE_ID'], 'kim.jisub.unipad')
            self.assertFalse(config['IS_ANALYTICS_ENABLED'])
            self.assertFalse(config['IS_GCM_ENABLED'])
            self.assertTrue(all('fake' in value.lower() or value.startswith(('1:000', '000', 'kim.jisub'))
                                for value in config.values() if isinstance(value, str)))


if __name__ == '__main__':
    unittest.main()
