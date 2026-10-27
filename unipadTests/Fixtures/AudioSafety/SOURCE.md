# Shared admission inputs

This directory copies the complete fourth revision of the generated audio admission
inputs from [unipad.io at a9f8e648065f91dc386a1fbd12e78cc6b8cb7b6a](https://github.com/kimjisub/unipad.io/tree/a9f8e648065f91dc386a1fbd12e78cc6b8cb7b6a/src/lib/unipack/__fixtures__/audio-safety).
The 85 binary files, `cases.json`, and `AudioSafetyREADME.md` (upstream `README.md`)
are byte-for-byte copies. The guide has a unique resource name to avoid collisions
with other fixture guides in the test bundle.
The manifest SHA-256 is `08e51f9cf9ae53de55080e9bd560d1a3395f76fb544d7e24bd83ab6b6d3e1d76`.
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

## Native containers outside the shared contract

AIFF, AIFC and CAF are excluded as `INVALID_FORMAT`, regardless of their extension
or whether a native decoder can open them. The fourth revision includes PCM AIFF,
sound-before-format AIFF, mu-law AIFC, PCM/IMA4/AAC/ALAC CAF, AIFF named as MP3,
and chained misleading MPEG headers before a normal MP3 stream. The guide records
why these inputs are excluded and how a single leading false MPEG header differs.

The generated native-container tests still prove that CAF PCM and AIFF/AIFC PCM
can decode, while requiring inspection to exclude them. `ssnd-first.aiff` also
retains its native decoding check of 13,230 mono frames at 44.1 kHz.
These are deliberate format boundaries, not evidence of damaged audio.

G.711 mu-law and A-law WAV in `../NativeAudio` remain a separate shared
structural-reader coverage gap and keep their existing `INVALID_FORMAT`
expectations. None of these checks certifies playback integration or changes the
currently connected decoder.
