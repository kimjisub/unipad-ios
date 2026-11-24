import array
import math
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

    def write(self, sounds=(), onset=0.8, swap=False, repeat_for=1, delays=None):
        data = array.array("h", [0]) * (48000 * 4 * 2)
        for index, name in enumerate(sounds):
            start = onset + (delays[index] if delays else 0)
            tone = self.sound(name)
            tone = (tone * 2)[:int(repeat_for * 48000) * 2]
            for i, value in enumerate(tone):
                at = int(start * 48000) * 2 + (i ^ 1 if swap else i)
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

    def test_unrelated_audio_before_or_after_the_reference_is_rejected(self):
        for rate in (8000, 48000):
            for correct_at, wrong_at in ((0.8, 1.8), (1.8, 0.8)):
                for wrong_channel in (0, 1, None):
                    with self.subTest(rate=rate, correct_at=correct_at, wrong_channel=wrong_channel):
                        data = array.array("h")
                        for frame in range(4 * rate):
                            for channel, (correct, wrong) in enumerate(((440, 662), (880, 998))):
                                hz = correct if correct_at <= frame / rate < correct_at + 1 else 0
                                if wrong_at <= frame / rate < wrong_at + 1 and wrong_channel in (None, channel):
                                    hz = wrong
                                data.append(round(8000 * math.sin(2 * math.pi * hz * frame / rate)) if hz else 0)
                        with wave.open(str(self.path), "wb") as f:
                            f.setparams((2, 2, rate, 0, "NONE", "not compressed"))
                            f.writeframes(data.tobytes())
                        result = self.verdict()
                        self.assertEqual(result["status"], "fail", result)
                        self.assertIn("unexpected waveform", result["reason"])

    def shifted_capture(self, rate, offset, seconds, wrong_channel, wrong_at=1.8):
        data = array.array("h")
        for frame in range(4 * rate):
            for channel, correct in enumerate((440, 880)):
                hz = correct if round(0.8 * rate) <= frame < round(1.8 * rate) else 0
                if (round(wrong_at * rate) <= frame < round((wrong_at + seconds) * rate)
                        and wrong_channel in (None, channel)):
                    hz = correct + offset
                data.append(round(8000 * math.sin(2 * math.pi * hz * frame / rate)) if hz else 0)
        with wave.open(str(self.path), "wb") as sound:
            sound.setparams((2, 2, rate, 0, "NONE", "not compressed"))
            sound.writeframes(data.tobytes())

    def test_sustained_near_reference_audio_is_rejected(self):
        for rate in (8000, 48000):
            for offset in (-60, -40, -20, -10, 10, 20, 40, 60):
                for seconds in (0.1, 0.25, 1.0):
                    for channel in (0, 1, None):
                        with self.subTest(rate=rate, offset=offset, seconds=seconds, channel=channel):
                            self.shifted_capture(rate, offset, seconds, channel)
                            result = self.verdict()
                            self.assertEqual(result["status"], "fail", result)
                            self.assertIn("unexpected waveform", result["reason"])

    def test_one_boundary_window_remains_a_reported_resolution_limit(self):
        for rate in (8000, 48000):
            for channel in (0, 1, None):
                with self.subTest(rate=rate, channel=channel):
                    self.shifted_capture(rate, 40, 0.04, channel)
                    result = self.verdict()
                    self.assertEqual(result["status"], "pass", result)
                    for index, measurement in enumerate(result["channels"]):
                        self.assertEqual(measurement["partial_windows"],
                                         1 if channel in (None, index) else 0)
                        self.assertEqual(measurement["partial_window_limit"], 2)
                    self.assertEqual(result["thresholds"]["partial_resolution_seconds"], 0.04)

    def test_near_reference_window_inside_steady_tone_is_not_an_edge(self):
        for rate in (8000, 48000):
            with self.subTest(rate=rate):
                self.shifted_capture(rate, 10, 0.04, None, wrong_at=1.2)
                result = self.verdict()
                self.assertEqual(result["status"], "fail", result)
                self.assertIn("unexpected waveform", result["reason"])
                self.assertEqual(result["channels"][0]["partial_windows"], 0)
                self.assertEqual(result["channels"][0]["partial_window_limit"], 2)

    def test_partial_reference_windows_at_onset_and_fade_still_pass(self):
        for onset in (0.801, 0.819, 0.837):
            with self.subTest(onset=onset):
                self.write(["pad-a.wav"], onset=onset)
                result = self.verdict()
                self.assertEqual(result["status"], "pass", result)

    def test_isolated_or_consecutive_wrong_windows_are_rejected(self):
        for onset, seconds in ((2.2, 0.04), (1.8, 0.08), (1.2, 0.08)):
            with self.subTest(onset=onset, seconds=seconds):
                self.write(["pad-a.wav"])
                with wave.open(str(self.path), "rb") as f:
                    data = array.array("h", f.readframes(f.getnframes()))
                tone = self.sound("pad-b.wav")[:int(seconds * 48000) * 2]
                start = int(onset * 48000) * 2
                data[start:start + len(tone)] = tone
                with wave.open(str(self.path), "wb") as f:
                    f.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
                    f.writeframes(data.tobytes())
                result = self.verdict()
                self.assertEqual(result["status"], "fail", result)
                self.assertIn("unexpected waveform", result["reason"])

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

    def test_staggered_reference_onsets_and_fades_pass(self):
        for onset in (0.801, 0.819, 0.832, 0.837):
            for delay in (0.001, 0.01, 0.02, 0.031):
                for delays in ((0, delay), (delay, 0)):
                    with self.subTest(onset=onset, delays=delays):
                        self.write(["pad-a.wav", "pad-b.wav"], onset=onset, delays=delays)
                        result = self.verdict(expected=((440, 662), (880, 998)), mixed=True)
                        self.assertEqual(result["status"], "pass", result)

    def test_single_and_repeated_wrong_windows_beside_reference_are_rejected(self):
        for rate in (8000, 48000):
            for wrong_channel in (0, 1, None):
                # One adjacent wrong chunk before, after and inside a normal
                # tone, then eight wrong chunks alternating with normal ones.
                for wrong_at in ((0.76,), (1.6,), (1.2,),
                                 tuple(1.6 + 0.08 * index for index in range(8))):
                    with self.subTest(rate=rate, wrong_channel=wrong_channel, wrong_at=wrong_at):
                        data = array.array("h")
                        wrong_frames = {frame for start in wrong_at
                                        for frame in range(round(start * rate), round((start + 0.04) * rate))}
                        normal_frames = set(range(round(0.8 * rate), round(1.6 * rate)))
                        alternating_frames = (set(range(round(1.6 * rate), round(2.24 * rate)))
                                              if len(wrong_at) > 1 else set())
                        for frame in range(4 * rate):
                            for channel, (correct, wrong) in enumerate(((440, 662), (880, 998))):
                                affected = wrong_channel in (None, channel)
                                hz = correct if (frame in normal_frames or
                                                 affected and frame in alternating_frames) else 0
                                if frame in wrong_frames and affected:
                                    hz = wrong
                                data.append(round(8000 * math.sin(2 * math.pi * hz * frame / rate)) if hz else 0)
                        with wave.open(str(self.path), "wb") as f:
                            f.setparams((2, 2, rate, 0, "NONE", "not compressed"))
                            f.writeframes(data.tobytes())
                        result = self.verdict()
                        self.assertEqual(result["status"], "fail", result)
                        self.assertIn("unexpected waveform", result["reason"])

    def test_loop_restart_adds_measured_edges_to_partial_budget(self):
        # The repeat's fade/restart lies inside a chunk, with no silent chunk.
        # A one-shot and a two-play loop must derive different edge budgets.
        for duration, edges in ((1, 2), (1.2, 4)):
            with self.subTest(duration=duration):
                self.write(["pad-a.wav"], onset=0.826, repeat_for=duration)
                self.input["completed_ns"] = 102_200_000_000
                result = self.verdict(stopped=duration > 1)
                self.assertEqual(result["status"], "pass", result)
                for channel in result["channels"]:
                    self.assertEqual(channel["partial_window_limit"], edges)
                    self.assertLessEqual(channel["partial_windows"], edges)

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

    def test_stopped_loop_reserves_stop_tail_not_another_full_play(self):
        self.write(["pad-a.wav"], repeat_for=1.2)
        self.input["completed_ns"] = 102_600_000_000
        self.assertEqual(self.verdict(stopped=True)["status"], "pass",
                         "a stopped loop has room for residual output and the quiet tail")
        self.input["completed_ns"] = 103_500_000_000
        self.assertEqual(self.verdict(stopped=True)["status"], "environment_unverified",
                         "the same four-second capture must still contain the entire quiet tail")

    def test_process_selection_requires_exact_owned_unique_bundle(self):
        mine = {"pid": 12, "bundle_id": "kim.jisub.unipad", "in_this_simulator": True}
        other = {"pid": 13, "bundle_id": "kim.jisub.unipad", "in_this_simulator": False}
        self.assertEqual(output.select_process([mine, other]), 12)
        for entries in [[], [other], [mine, dict(mine, pid=14)]]:
            with self.assertRaises(ValueError):
                output.select_process(entries)


if __name__ == "__main__":
    unittest.main()
