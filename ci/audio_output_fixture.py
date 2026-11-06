#!/usr/bin/env python3
"""Generate owned, fixed references for an external pad-output check.

No playback, recording, device access, or third-party audio is involved. Existing
directories are refused so regenerating a reference cannot overwrite evidence.
"""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import sys
import wave

RATE = 48000
FRAMES = RATE
AMPLITUDE = 8000
FADE_FRAMES = 480
TONES = {
    "pad-a.wav": (440, 880),
    "pad-b.wav": (662, 998),
    "left.wav": (1110, 0),
    "right.wav": (0, 1374),
    "silence.wav": (0, 0),
}
MAPPING = [(1, "pad-a.wav", 1), (2, "pad-b.wav", 1), (3, "left.wav", 1),
           (4, "right.wav", 1), (5, "silence.wav", 1), (6, "pad-a.wav", 0)]


def generate(root: Path) -> dict:
    """Write a new UniPack and its reference manifest; preserve any existing path."""
    root = Path(root)
    root.mkdir(parents=True, exist_ok=False)
    (root / "sounds").mkdir()
    (root / "info").write_text(
        "title=Audio Output Fixture\nproducerName=Tests\n"
        "buttonX=8\nbuttonY=8\nchain=1\nsquareButton=true\n", encoding="utf-8")
    (root / "keySound").write_text(
        "".join(f"1 1 {column} {name} {plays}\n" for column, name, plays in MAPPING),
        encoding="utf-8")
    for name, frequencies in TONES.items():
        samples = array.array("h")
        for frame in range(FRAMES):
            envelope = min(1, frame / FADE_FRAMES, (FRAMES - 1 - frame) / FADE_FRAMES)
            for hz in frequencies:
                samples.append(round(AMPLITUDE * envelope * math.sin(2 * math.pi * hz * frame / RATE)))
        if sys.byteorder != "little":
            samples.byteswap()
        with wave.open(str(root / "sounds" / name), "wb") as sound:
            sound.setparams((2, 2, RATE, FRAMES, "NONE", "not compressed"))
            sound.writeframes(samples.tobytes())
    manifest = {
        "fixture_version": 1,
        "sample_rate": RATE,
        "frames_per_sound": FRAMES,
        "sample_format": "s16le",
        "channel_order": ["left", "right"],
        "peak_amplitude": AMPLITUDE,
        "fade_frames": FADE_FRAMES,
        "frequencies_hz": {name: list(hz) for name, hz in TONES.items()},
        "pads": [{"chain": 1, "row": 1, "column": column, "sound": name,
                  "total_plays": plays, "held_loop": plays == 0}
                 for column, name, plays in MAPPING],
        "unmapped_control": {"chain": 1, "row": 1, "column": 8},
        "sha256": {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in sorted(root.rglob("*")) if path.is_file()},
    }
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new directory for the reference pack")
    args = parser.parse_args()
    print(json.dumps(generate(args.output), indent=2))


if __name__ == "__main__":
    main()
