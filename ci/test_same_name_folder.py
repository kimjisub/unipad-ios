"""Run ci/same-name-folder.sh against a simulator data folder laid out like CoreSimulator's."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SameNameFolderTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(dir=os.environ.get("UNIPAD_TEST_TMPDIR"))
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        self.groups = self.home / "Library/Developer/CoreSimulator/Devices/sim/data/Containers/Shared/AppGroup"

    def group(self, name, identifier):
        folder = self.groups / name
        folder.mkdir(parents=True)
        with open(folder / ".com.apple.mobile_container_manager.metadata.plist", "wb") as metadata:
            plistlib.dump({"MCMMetadataIdentifier": identifier}, metadata)
        return folder

    def run_script(self, action):
        return subprocess.run(["ci/same-name-folder.sh", action, "sim"], cwd=ROOT, capture_output=True,
                              text=True, timeout=15, env=dict(os.environ, HOME=str(self.home)))

    def test_folder_is_added_to_on_my_iphone_and_removed_afterwards(self):
        self.group("A", "group.com.apple.other")
        storage = self.group("B", "group.com.apple.FileProvider.LocalStorage") / "File Provider Storage"
        storage.mkdir()
        (storage / "Faded.zip").write_text("user file")

        added = self.run_script("add")
        self.assertEqual(added.returncode, 0, added.stderr)
        self.assertEqual(sorted(path.name for path in storage.iterdir()), ["Faded.zip", "unipad"])
        self.assertTrue(any((storage / "unipad").iterdir()), "an empty folder may be hidden by the picker")

        removed = self.run_script("remove")
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertEqual([path.name for path in storage.iterdir()], ["Faded.zip"])

    def test_remove_keeps_a_folder_holding_other_files(self):
        storage = self.group("B", "group.com.apple.FileProvider.LocalStorage") / "File Provider Storage"
        self.assertEqual(self.run_script("add").returncode, 0)
        (storage / "unipad" / "kept.txt").write_text("someone else's file")

        removed = self.run_script("remove")
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertEqual([path.name for path in (storage / "unipad").iterdir()], ["kept.txt"])

    def test_simulator_without_on_my_iphone_storage_is_left_alone(self):
        self.group("A", "group.com.apple.other")
        added = self.run_script("add")
        self.assertEqual(added.returncode, 0, added.stderr)
        self.assertIn("no same-name folder added", added.stderr)
        self.assertEqual(self.run_script("remove").returncode, 0)
        self.assertEqual([path.name for path in self.groups.iterdir()], ["A"])


if __name__ == "__main__":
    unittest.main()
