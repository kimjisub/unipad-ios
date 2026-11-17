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
The mixed case crosses these adjacent pads with one fast screen gesture and
enables sliding through a launch-only preference override. Separate XCUITest
taps wait for UI idleness between inputs and can let the first sample finish
before the second starts, especially on iPad. This checks overlapping output
from the real pad input path; it does not establish simultaneous fingers.

Generate a new copy without overwriting an existing reference or result:

```sh
python3 ci/audio_output_fixture.py /path/to/new/reference-pack
python3 -m unittest discover -s ci -p test_audio_output_fixture.py -v
```

Run the opt-in external check on an already acquired simulator:

```sh
python3 ci/audio_output_check.py --simulator "$SIMULATOR_UDID" \
  --generation "$RENTAL_GENERATION" --device-tools /path/to/managed-device-tools \
  --recorder-binary /path/to/managed/process-tap \
  --derived-data /path/to/DerivedData --output /path/to/new/positive --repeats 3
```

The device tools directory must provide `devices.py` (generation-protected app
installation, file staging, process selection, and `record --pid --ready`) and
`ios_tests.py`. The recorder must already have system audio permission. This
script neither grants permission nor changes the Mac's output device. Return
the simulator through its device tool as soon as device work ends.

Before requesting any recording, XCUITest opens the staged pack through the
shared isolated-library helpers and waits up to 30 seconds for the loading
overlay's text to disappear. A timeout ends as environment unverified without
judging playback; the menu and pad grid alone do not establish audio readiness.
Each XCUITest input follows recorder readiness and a 0.5-second quiet baseline.
The host signals `target-ready` after selecting the owned process and hashing
the installed app. This is a preparation boundary, not evidence of audio packets.
The UI allows 12 seconds for that preparation, then a separate 12 seconds for
the recorder's readiness notice; the host's recording-ready limit remains 10
seconds. Discovery must not consume the ready window and cause the UI to
terminate the app while the recorder is resolving its sound object.
The recorder drops the initial 0.1 seconds. Both processes use `CLOCK_UPTIME_RAW`
timestamps to locate input in the WAV. The actual reference is played only by
the real app's pads. Every case preserves its original four-second WAV, readiness
notice, input times, selected process, recorder result, and numeric verdict.
The suite also preserves build/test logs, the result bundle, app and recorder
hashes, source commit and diff hash, environment, and staged pack hashes. Callback
padding remains in the original; analysis is restricted to the first four seconds.
The app identity hashes a versioned manifest of every installed bundle file,
including `unipad.debug.dylib` and resources. Hashing only the small Debug launcher
would not identify changes to the app's actual code. The full manifest is kept
with each recording; receipts without that identity cannot validate a new trial.
Existing output folders are refused. Archive each round before another round.
Preparation and unexpected errors exit 2 and preserve an error in `summary.json`.
When the requested output already exists, its evidence is left intact and the
error summary is written to a new sibling `<output>-error-*` directory, printed
on stderr. An unwritable evidence location is reported on stderr and also exits 2.
Missing callback frames or an overflowing packet log also make a capture
incomplete. Such a recording is preserved and rejected before judging playback.

The versioned thresholds in `ci/audio_output.py` require -50 dBFS RMS and 20 dB
over a nonzero baseline, with a quiet baseline/tail below -65 dBFS. Phase-neutral
reference fitting runs in 40 ms windows: expected frequencies must explain at
least 85% of power, each mixed component at least 15%, and each one-shot tone
must match for 0.75–1.16 s. Channel matches must remain continuous for at least
0.75 s; both mixed pads must overlap continuously for at least 0.25 s. The loop is held for 1.2 s,
must match for at least 1.05 s (beyond a single play), and must be quiet within
0.1 s of gesture completion. These limits check a repeatable digital
signal, not physical input latency. A different reference must be rejected.
Within the same four-second capture, a stopped loop reserves 0.1 s of residual
output and the final 0.5 s of quiet after gesture completion. A one-shot reserves
another full second of playback and that quiet tail.

To validate the checker, repeat with a new output directory and
`--block-playback --reuse-build --verified-capture /path/to/positive/summary.json`. The blocked
trial maps every sound to the owned silent file; it must exit **1**. Run the
normal configuration again afterwards with `--reuse-build` and the same
`--verified-capture`; it must exit **0**. Reusing the test build prevents another
link step from changing the app between controls. Keep its derived data unchanged
until all three trials finish. The positive receipt
only establishes the recording environment and must match the app, recorder,
source and device. It never replaces a new recording or makes a silent recording
pass. Missing permission, packets, timestamps, ownership or the timing budget is
**environment unverified**, exit **2**, and never an output pass. A first entirely
silent run without a verified recording path also exits 2.

`ci/ui-tests.sh` excludes this class because it needs the external recorder; run
it separately when checking the whole UI suite. These tests do not verify
physical speakers, headphones, Bluetooth, sound quality, or performance latency.
