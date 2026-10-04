"""Keep named platform images compilable without recursion on macOS."""
import os
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == 'Darwin', 'Requires the macOS AppKit SDK')
class PlatformImageCompilationTests(unittest.TestCase):
    def test_named_image_compiles_without_recursion_for_macos(self):
        source = Path(__file__).resolve().parents[1] / 'unipad/Utils/PlatformImage.swift'
        with tempfile.TemporaryDirectory(dir=os.environ.get('PAPERCLIP_RUN_SCRATCH_DIR')) as directory:
            probe = Path(directory) / 'PlatformImage.swift'
            probe.write_text(source.read_text() + '''
func loadNamedPlatformImage(_ name: String) -> PlatformImage? {
    PlatformImage(named: name)
}
''')
            result = subprocess.run(
                ['xcrun', '--sdk', 'macosx', 'swiftc', '-c', '-O',
                 '-target', f'{platform.machine()}-apple-macosx14.0', str(probe),
                 '-o', str(Path(directory) / 'PlatformImage.o')],
                capture_output=True, text=True, timeout=120,
            )
            diagnostics = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, diagnostics)
            self.assertNotIn('infinite recursion', diagnostics.lower(), diagnostics)


if __name__ == '__main__':
    unittest.main()
