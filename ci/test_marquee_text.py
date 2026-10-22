"""Keep the shared marquee view compilable with AppKit on macOS."""
import platform
from pathlib import Path
import subprocess
import unittest


@unittest.skipUnless(platform.system() == 'Darwin', 'Requires the macOS SwiftUI SDK')
class MarqueeTextCompilationTests(unittest.TestCase):
    def test_shared_view_compiles_for_macos(self):
        source = Path(__file__).resolve().parents[1] / 'unipad/Views/Components/MarqueeText.swift'
        result = subprocess.run(
            ['xcrun', '--sdk', 'macosx', 'swiftc', '-typecheck',
             '-target', f'{platform.machine()}-apple-macosx14.0', str(source)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
