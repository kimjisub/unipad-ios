import array
from pathlib import Path
import tempfile
import unittest
import wave

import audio_output as output


class AudioOutputTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.path = Path(self.scratch.name) / "capture.wav"
        self.ready = {"ready": True, "clock": "CLOCK_UPTIME_RAW",
                      "first_frame_monotonic_ns": 100_000_000_000,
                      "notified_monotonic_ns": 100_020_000_000,
                      "initial_discard_seconds": 0.1}
        self.input = {"invoked_ns": 100_600_000_000, "completed_ns": 100_900_000_000}

    def sound(self, name):
        root = Path(__file__).resolve().parents[1] / "test-fixtures/AudioOutput/sounds"
        with wave.open(str(root / name), "rb") as f:
            return array.array("h", f.readframes(f.getnframes()))

    def write(self, sounds=(), onset=0.8, swap=False, repeat_for=1):
        data = array.array("h", [0]) * (48000 * 4 * 2)
        for name in sounds:
            tone = self.sound(name)
            tone = (tone * 2)[:int(repeat_for * 48000) * 2]
            for i, value in enumerate(tone):
                at = int(onset * 48000) * 2 + (i ^ 1 if swap else i)
                data[at] += value
        with wave.open(str(self.path), "wb") as f:
            f.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
            f.writeframes(data.tobytes())

    def verdict(self, expected=((440,), (880,)), **kwargs):
        return output.assess(self.path, self.ready, self.input, expected, **kwargs)

    def test_normal_reference_matches_each_channel(self):
        self.write(["pad-a.wav"])
        result = self.verdict()
        self.assertEqual(result["status"], "pass", result)
        self.assertGreater(result["matched_seconds"], 0.85)
        self.assertEqual(len(result["channels"]), 2)

    def test_other_pad_and_swapped_channels_cannot_pass(self):
        self.write(["pad-b.wav"])
        self.assertEqual(self.verdict()["status"], "fail")
        self.write(["pad-a.wav"], swap=True)
        self.assertEqual(self.verdict()["status"], "fail")

    def test_silence_fails_normal_but_passes_explicit_silent_control(self):
        self.write()
        self.assertEqual(self.verdict()["status"], "fail")
        self.assertEqual(self.verdict(expected=((), ()))["status"], "pass")

    def test_single_channel_reference_does_not_tolerate_other_channel(self):
        self.write(["left.wav"])
        self.assertEqual(self.verdict(expected=((1110,), ()))["status"], "pass")
        self.assertEqual(self.verdict()["status"], "fail")

    def test_mixed_output_requires_both_pad_signatures_together(self):
        expected = ((440, 662), (880, 998))
        self.write(["pad-a.wav", "pad-b.wav"])
        self.assertEqual(self.verdict(expected=expected, mixed=True)["status"], "pass")
        self.write(["pad-a.wav"])
        self.assertEqual(self.verdict(expected=expected, mixed=True)["status"], "fail")

    def test_short_click_and_stale_audio_do_not_pass(self):
        self.write(["pad-a.wav"], onset=0)
        self.assertNotEqual(self.verdict()["status"], "pass")
        self.write(["pad-a.wav"])
        with wave.open(str(self.path), "rb") as f:
            data = array.array("h", f.readframes(f.getnframes()))
        data[int(0.9 * 48000) * 2:] = array.array("h", [0]) * (len(data) - int(0.9 * 48000) * 2)
        with wave.open(str(self.path), "wb") as f:
            f.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
            f.writeframes(data.tobytes())
        self.assertEqual(self.verdict()["status"], "fail")

    def test_extra_repeat_and_a_gap_in_the_middle_are_rejected(self):
        self.write(["pad-a.wav"], repeat_for=2)
        self.assertEqual(self.verdict()["status"], "fail", "a one-shot must not repeat")
        self.write(["pad-a.wav"])
        with wave.open(str(self.path), "rb") as f:
            data = array.array("h", f.readframes(f.getnframes()))
        first, last = int(1.24 * 48000) * 2, int(1.28 * 48000) * 2
        data[first:last] = array.array("h", [0]) * (last - first)
        with wave.open(str(self.path), "wb") as f:
            f.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
            f.writeframes(data.tobytes())
        self.assertEqual(self.verdict()["status"], "fail", "a middle gap must not be excused by total signal length")

    def test_missing_permission_or_timestamp_is_unverified(self):
        self.assertEqual(self.verdict()["status"], "environment_unverified")
        self.write(["pad-a.wav"])
        self.ready["first_frame_monotonic_ns"] = None
        self.assertEqual(self.verdict()["status"], "environment_unverified")

    def test_late_input_does_not_accuse_the_app(self):
        self.write()
        self.input = {"invoked_ns": 103_000_000_000, "completed_ns": 103_500_000_000}
        self.assertEqual(self.verdict()["status"], "environment_unverified")

    def test_stop_requires_quiet_tail_after_the_gesture(self):
        self.write(["pad-a.wav"])
        self.input["completed_ns"] = 102_000_000_000
        self.assertEqual(self.verdict(stopped=True)["status"], "fail",
                         "a single play cannot prove the held sample repeated")
        self.write(["pad-a.wav"], repeat_for=1.2)
        self.assertEqual(self.verdict(stopped=True)["status"], "pass")
        self.input["completed_ns"] = 101_000_000_000
        self.assertEqual(self.verdict(stopped=True)["status"], "fail")

    def test_process_selection_requires_exact_owned_unique_bundle(self):
        mine = {"pid": 12, "bundle_id": "kim.jisub.unipad", "in_this_simulator": True}
        other = {"pid": 13, "bundle_id": "kim.jisub.unipad", "in_this_simulator": False}
        self.assertEqual(output.select_process([mine, other]), 12)
        for entries in [[], [other], [mine, dict(mine, pid=14)]]:
            with self.assertRaises(ValueError):
                output.select_process(entries)


if __name__ == "__main__":
    unittest.main()
