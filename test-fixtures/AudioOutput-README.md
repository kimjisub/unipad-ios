# Audio output references

`AudioOutput` is an owned, deterministic UniPack for an opt-in external output
check. Each stereo PCM reference lasts exactly one second at 48 kHz / 16 bits.
The first and last 10 ms fade to zero. Peak amplitude is 8000 (about -12.25 dBFS).
The committed WAVs are the reference waveforms; `manifest.json` records their
SHA-256 hashes, channel order, frequencies, and exact pad mapping.

All pads use chain 1, row 1:

| Column | Left | Right | Behavior |
| --- | --- | --- | --- |
| 1 | 440 Hz | 880 Hz | One play |
| 2 | 662 Hz | 998 Hz | Different pad, one play |
| 3 | 1110 Hz | Digital silence | Left only |
| 4 | Digital silence | 1374 Hz | Right only |
| 5 | Digital silence | Digital silence | Valid silent file |
| 6 | 440 Hz | 880 Hz | Repeat while held; release stops it |
| 8 | No mapping | No mapping | Press without a playback request |

Columns 1 and 2 can overlap to check mixed output. There are no LEDs or autoplay
instructions that could start a sample before a screen press. Never substitute
playing these WAVs in the recorder for pressing the actual app's pads.

Generate a new copy without overwriting an existing reference or result:

```sh
python3 ci/audio_output_fixture.py /path/to/new/reference-pack
python3 -m unittest discover -s ci -p test_audio_output_fixture.py -v
```

These files alone do not verify output. The external check must establish the
lent simulator's exact app process, await recorder readiness, discard the initial
buffer, capture the quiet baseline and actual screen input, and compare each
channel with these references. Missing permission, packets, or readiness is an
unverified environment, never an output pass. Signal thresholds still require
calibration with repeated normal and silent controls. Physical speakers,
headphones, Bluetooth, sound quality, and performance latency are outside scope.
