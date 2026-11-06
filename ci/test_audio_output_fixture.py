import array
import hashlib
import json
import math
from pathlib import Path
import tempfile
import unittest
import wave

import audio_output_fixture as fixture


class AudioOutputFixtureTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name) / "pack"
        self.manifest = fixture.generate(self.root)

    def samples(self, name):
        with wave.open(str(self.root / "sounds" / name), "rb") as sound:
            self.assertEqual(sound.getparams()[:4], (2, 2, 48000, 48000))
            return array.array("h", sound.readframes(sound.getnframes()))

    @staticmethod
    def fraction(samples, channel, hz):
        # Independent sinusoidal projection of the middle 0.5 s, outside the fades.
        values = samples[24000 + channel:72000:2]
        sine = math.fsum(value * math.sin(2 * math.pi * hz * i / 48000)
                         for i, value in enumerate(values))
        cosine = math.fsum(value * math.cos(2 * math.pi * hz * i / 48000)
                           for i, value in enumerate(values))
        energy = math.sumprod(values, values)
        return 2 * (sine * sine + cosine * cosine) / (len(values) * energy)

    def test_pads_have_distinct_one_second_stereo_references(self):
        first, second = self.samples("pad-a.wav"), self.samples("pad-b.wav")
        for samples, tones in [(first, (440, 880)), (second, (662, 998))]:
            for channel, hz in enumerate(tones):
                self.assertGreater(self.fraction(samples, channel, hz), 0.999)
            self.assertLessEqual(max(abs(value) for value in samples), 8000)
            self.assertEqual(samples[:2], array.array("h", [0, 0]))
            self.assertEqual(samples[-2:], array.array("h", [0, 0]))
        self.assertLess(self.fraction(second, 0, 440), 0.0001)
        self.assertLess(self.fraction(first, 1, 998), 0.0001)

    def test_single_channel_and_silent_controls_are_digital_silence(self):
        left, right, silent = [self.samples(name) for name in
                               ("left.wav", "right.wav", "silence.wav")]
        self.assertTrue(any(left[::2]))
        self.assertFalse(any(left[1::2]))
        self.assertFalse(any(right[::2]))
        self.assertTrue(any(right[1::2]))
        self.assertFalse(any(silent))

    def test_real_pad_mapping_includes_held_loop_and_unmapped_control(self):
        mapping = (self.root / "keySound").read_text().splitlines()
        self.assertEqual(mapping, ["1 1 1 pad-a.wav 1", "1 1 2 pad-b.wav 1",
                                   "1 1 3 left.wav 1", "1 1 4 right.wav 1",
                                   "1 1 5 silence.wav 1", "1 1 6 pad-a.wav 0"])
        self.assertFalse(any(line.startswith("1 1 8 ") for line in mapping))
        self.assertFalse((self.root / "autoPlay").exists())
        self.assertFalse((self.root / "keyLed").exists())

    def test_hashes_cover_every_reference_and_pack_instruction(self):
        files = {p.relative_to(self.root).as_posix(): p for p in self.root.rglob("*")
                 if p.is_file() and p.name != "manifest.json"}
        self.assertEqual(set(files), set(self.manifest["sha256"]))
        for name, path in files.items():
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),
                             self.manifest["sha256"][name])
        self.assertEqual(json.loads((self.root / "manifest.json").read_text()), self.manifest)
        other = Path(self.scratch.name) / "other"
        self.assertEqual(fixture.generate(other), self.manifest)

    def test_generation_preserves_existing_content(self):
        protected = self.root / "sounds/pad-a.wav"
        protected.write_bytes(b"existing content")
        with self.assertRaises(FileExistsError):
            fixture.generate(self.root)
        self.assertEqual(protected.read_bytes(), b"existing content")

    def test_committed_fixture_matches_the_generator(self):
        committed = Path(__file__).resolve().parents[1] / "test-fixtures/AudioOutput"
        for name in [*self.manifest["sha256"], "manifest.json"]:
            self.assertEqual((committed / name).read_bytes(), (self.root / name).read_bytes(), name)


if __name__ == "__main__":
    unittest.main()
