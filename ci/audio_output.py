#!/usr/bin/env python3
"""Assess an external stereo capture against the owned AudioOutput references.

The caller must establish recorder permission, target ownership and completeness.
Only the first four seconds are assessed; recorder callback padding is retained
in the original WAV. No audio is played by this module.
"""
import array
from functools import lru_cache
import math
from pathlib import Path
import sys
import wave

THRESHOLDS = {"version": 3, "signal_dbfs": -50, "quiet_dbfs": -65,
              "baseline_gain_db": 20, "fit_fraction": 0.85, "component_fraction": 0.15,
              "minimum_tone_seconds": 0.75, "minimum_overlap_seconds": 0.25,
              "minimum_loop_seconds": 1.05,
              "maximum_one_shot_seconds": 1.16,
              "stop_tail_seconds": 0.1, "chunk_seconds": 0.04,
              "envelope_seconds": 0.01}


def select_process(entries):
    matches = [entry["pid"] for entry in entries if entry.get("in_this_simulator") is True
               and entry.get("bundle_id") == "kim.jisub.unipad"
               and isinstance(entry.get("pid"), int) and entry["pid"] > 0]
    if len(matches) != 1:
        raise ValueError(f"expected one owned UniPad sound process, found {matches}")
    return matches[0]


def dbfs(value):
    return 20 * math.log10(value / 32768) if value else None


def levels(values):
    return {"rms_dbfs": dbfs(math.sqrt(math.sumprod(values, values) / len(values))) if values else None,
            "peak_dbfs": dbfs(max(map(abs, values), default=0)), "frames": len(values)}


def quiet(values):
    rms = levels(values)["rms_dbfs"]
    return rms is None or rms < THRESHOLDS["quiet_dbfs"]


@lru_cache(maxsize=128)
def basis(rate, hz, count):
    return ([math.sin(2 * math.pi * hz * i / rate) for i in range(count)],
            [math.cos(2 * math.pi * hz * i / rate) for i in range(count)])


def fit(values, rate, hz):
    energy = math.sumprod(values, values)
    if not energy:
        return 0
    sine, cosine = basis(rate, hz, len(values))
    # Both phases are fitted: an output device may shift the reference's phase.
    return 2 * (math.sumprod(values, sine) ** 2 + math.sumprod(values, cosine) ** 2) / (len(values) * energy)


@lru_cache(maxsize=128)
def envelope_basis(rate, frequencies, count):
    # Within 10 ms, each reference can ramp independently. Orthonormalize the
    # constant and linear envelopes together so overlapping frequencies/phases
    # are fitted jointly, without counting their shared energy twice.
    vectors = []
    for hz in frequencies:
        for phase in basis(rate, hz, count):
            for ramp in (False, True):
                vector = [value * (i / max(1, count - 1) if ramp else 1)
                          for i, value in enumerate(phase)]
                for previous in vectors:
                    projection = math.sumprod(vector, previous)
                    vector = [value - projection * ref for value, ref in zip(vector, previous)]
                norm = math.sqrt(math.sumprod(vector, vector))
                if norm > 1e-9:
                    vectors.append([value / norm for value in vector])
    return vectors


def partial_reference_fit(values, rate, frequencies):
    """Fit onsets/fades by their waveform, never by a neighbouring verdict."""
    floor = 32768 * 10 ** (THRESHOLDS["quiet_dbfs"] / 20)
    audible = [i for i, value in enumerate(values) if abs(value) >= floor]
    if not audible:
        return 0
    values = values[audible[0]:audible[-1] + 1]
    step = int(rate * THRESHOLDS["envelope_seconds"])
    energy = math.sumprod(values, values)
    explained = 0
    for at in range(0, len(values), step):
        window = values[at:at + step]
        vectors = envelope_basis(rate, tuple(frequencies), len(window))
        explained += sum(math.sumprod(window, vector) ** 2 for vector in vectors)
    return explained / energy if energy else 0


def assess(path, ready, gesture, expected, *, stopped=False, mixed=False):
    result = {"status": "environment_unverified", "thresholds": THRESHOLDS,
              "expected_hz": expected, "channels": []}

    def finish(status, reason):
        return result | {"status": status, "reason": reason}

    try:
        if (ready.get("ready") is not True or ready.get("clock") != "CLOCK_UPTIME_RAW"
                or not isinstance(ready.get("first_frame_monotonic_ns"), int)
                or ready.get("initial_discard_seconds", 0) < 0.1):
            return finish("environment_unverified", "missing recorder readiness or sample clock")
        first = ready["first_frame_monotonic_ns"]
        before = (gesture["invoked_ns"] - first) / 1e9
        after = (gesture["completed_ns"] - first) / 1e9
        # A held loop has already played when its gesture completes. Reserve
        # its stop residual and quiet tail, rather than another one-second play.
        remaining = 0.5 + (THRESHOLDS["stop_tail_seconds"] if stopped else 1.0)
        if (gesture["invoked_ns"] - ready["notified_monotonic_ns"] < 500_000_000
                or before < 0.5 or after < before or after > 4 - remaining):
            return finish("environment_unverified", "input did not leave the required baseline and tail")
        with wave.open(str(Path(path)), "rb") as sound:
            rate, channels = sound.getframerate(), sound.getnchannels()
            if sound.getsampwidth() != 2 or channels != 2 or not 8000 <= rate <= 192000:
                return finish("environment_unverified", "unsupported capture format")
            if sound.getnframes() / rate < 3.9:
                return finish("environment_unverified", "incomplete four-second capture")
            samples = array.array("h", sound.readframes(rate * 4))
            if sys.byteorder != "little":
                samples.byteswap()
    except (OSError, EOFError, wave.Error, KeyError, TypeError, ValueError) as error:
        return finish("environment_unverified", str(error))

    result.update(sample_rate=rate, input_start_seconds=before, input_end_seconds=after)
    chunk = int(rate * THRESHOLDS["chunk_seconds"])
    traces = []
    for channel, frequencies in enumerate(expected):
        values = samples[channel::2]
        baseline = values[int((before - 0.5) * rate):int(before * rate)]
        tail = values[-int(0.5 * rate):]
        measurement = {"baseline": levels(baseline), "whole": levels(values),
                       "tail": levels(tail), "tones": {str(hz): 0.0 for hz in frequencies}}
        result["channels"].append(measurement)
        if not quiet(baseline):
            return finish("environment_unverified", "audio preceded the current screen input")
        if not frequencies:
            if not quiet(values):
                return finish("fail", f"unexpected output on channel {channel}")
            continue
        if not quiet(tail):
            return finish("fail", "output did not end before the quiet tail")
        if stopped and not quiet(values[int((after + THRESHOLDS["stop_tail_seconds"]) * rate):]):
            return finish("fail", "loop remained audible after gesture completion")
        matches = set()
        unmatched_windows = set()
        active = []
        baseline_rms = measurement["baseline"]["rms_dbfs"]
        for at in range(int(before * rate), len(values) - chunk + 1, chunk):
            window = values[at:at + chunk]
            power = levels(window)["rms_dbfs"]
            if power is None or power < THRESHOLDS["signal_dbfs"]:
                continue
            if baseline_rms is not None and power < baseline_rms + THRESHOLDS["baseline_gain_db"]:
                continue
            fractions = [fit(window, rate, hz) for hz in frequencies]
            if sum(fractions) < THRESHOLDS["fit_fraction"]:
                # Verify the actual partial waveform; it cannot contribute to
                # the minimum full-tone or overlap durations below.
                if partial_reference_fit(window, rate, frequencies) < THRESHOLDS["fit_fraction"]:
                    unmatched_windows.add(at)
                continue
            for hz, fraction in zip(frequencies, fractions):
                if fraction >= THRESHOLDS["component_fraction"]:
                    measurement["tones"][str(hz)] += chunk / rate
            if all(fraction >= THRESHOLDS["component_fraction"] for fraction in fractions):
                matches.add(at)
                active.extend(window)
        measurement["unexpected_seconds"] = len(unmatched_windows) * chunk / rate
        if unmatched_windows:
            return finish("fail", f"unexpected waveform on channel {channel}")
        measurement["active"] = levels(active)
        measurement["matched_seconds"] = len(matches) * chunk / rate
        tone_minimum = THRESHOLDS["minimum_loop_seconds"] if stopped else THRESHOLDS["minimum_tone_seconds"]
        if any(seconds < tone_minimum for seconds in measurement["tones"].values()):
            return finish("fail", f"reference waveform missing or too short on channel {channel}")
        if not stopped and any(seconds > THRESHOLDS["maximum_one_shot_seconds"]
                               for seconds in measurement["tones"].values()):
            return finish("fail", "a one-shot reference repeated or did not stop")
        traces.append(matches)
    common = set.intersection(*traces) if traces else set()
    result["matched_seconds"] = len(common) * chunk / rate
    longest = length = 0
    previous = None
    for at in sorted(common):
        length = length + 1 if previous is not None and at - previous == chunk else 1
        longest = max(longest, length)
        previous = at
    result["continuous_matched_seconds"] = longest * chunk / rate
    minimum = THRESHOLDS["minimum_overlap_seconds"] if mixed else THRESHOLDS["minimum_tone_seconds"]
    if traces and result["continuous_matched_seconds"] < minimum:
        return finish("fail", "reference channels did not overlap for long enough")
    return finish("pass", "reference output and quiet controls match")
