"""Keep the shared audio admission tests compilable without UIKit."""
from pathlib import Path
import subprocess
import unittest


class AudioAdmissionCompileTests(unittest.TestCase):
    def test_shared_admission_tests_compile_on_macos(self):
        root = Path(__file__).resolve().parents[1]
        platform = Path(subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True,
        ).strip())
        audio = root / "unipad/Services/Audio"
        sources = [audio / name for name in (
            "AudioAdmission.swift", "AudioRead.swift", "AudioFileInspection.swift",
            "FlacAudioInspection.swift", "Mp4AudioInspection.swift",
            "Mp4OpusOggStream.swift", "OggAudioInspection.swift",
        )]
        sources += [root / "unipadTests" / name for name in (
            "AudioAdmissionTests.swift", "OggVorbisDecoderTests.swift",
        )]
        result = subprocess.run(
            ["xcrun", "swiftc", "-typecheck", "-D", "ADMISSION_STANDALONE",
             "-I", str(platform / "Developer/usr/lib"),
             "-F", str(platform / "Developer/Library/Frameworks"),
             *map(str, sources)],
            capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
