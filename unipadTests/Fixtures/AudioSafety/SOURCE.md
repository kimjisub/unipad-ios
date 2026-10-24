# Shared admission inputs

This directory copies the complete third revision of the generated audio admission
inputs from [unipad-android at cab0f17c373e6830c750c6f289d059c40907f4eb](https://github.com/kimjisub/unipad-android/tree/cab0f17c373e6830c750c6f289d059c40907f4eb/app/src/sharedTest/assets/audio-safety).
The binary files, `cases.json`, and `AudioSafetyREADME.md` (upstream `README.md`)
are byte-for-byte copies. The guide has a unique resource name to avoid collisions
with other fixture guides in the test bundle.
The manifest SHA-256 is `b16e4f635d671b3ab2d20222cea55bec72cce91e496d6b2ea87ccf6525c193c4`.
`AudioAdmissionTests` checks that hash and every binary hash without changing expectations.
These inputs are separate from the historical parser conformance corpus.

`AudioAdmission` and the structural readers follow the same integer admission and
codec inspection rules. File reads map the original bytes and do not allocate PCM.
MP4 chunk extents use two bounded integer arrays. Arithmetic is checked before
multiplication or addition, including untrusted 64-bit sizes. The eight large WAV
recipes are generated one at a time in the test process; production inspection skips
the PCM bytes and counts complete physically present frames.

Run the `unipadTests/AudioAdmissionTests` unit suite with Xcode. The inspector is
intentionally not connected to `SoundEngine` yet. It certifies neither successful
decoding nor identical audible duration or peak device memory. Decoder delay,
trim, malformed codec payloads, physical device memory limits, output devices and
failure messages need separate playback verification. In particular, ALAC reads
the first channel element's output count, as in the shared implementation; entropy
decoding and remaining channel elements are not certified by this structural pass.

Separate generated native-container tests retain the existing CAF PCM and AIFF/AIFC
PCM path. These extra tests do not modify the shared corpus.

## Native decoder coverage gaps before playback integration

The structural inspector currently reports `INVALID_FORMAT` for these valid inputs:

| Container | Codec |
| --- | --- |
| WAV | G.711 mu-law and A-law |
| CAF | AAC, ALAC and IMA4 |
| AIFC | mu-law |

The native decoder on macOS reads 13,230 frames from each corresponding fixture
in `../NativeAudio`. `testKnownNativeDecoderFormatsRemainExplicitlyExcluded`
records the current structural result. These files expose a known coverage gap;
the result does not establish that their audio is damaged. Existing playback
support must be preserved when resolving shared format coverage before connecting
this inspector to pack loading. This change leaves that shared support decision
pending and keeps the six codec results unchanged.

The separate `ssnd-first.aiff` fixture verifies valid AIFF chunk ordering: sound
data may precede `COMM`. Both the native decoder and the inspector must read
13,230 mono frames at 44.1 kHz. The extra fixtures and their observations remain
separate from the unchanged shared manifest and its expected values.
