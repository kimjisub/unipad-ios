# Shared admission inputs

This directory copies the complete third revision of the generated audio admission
inputs from [unipad-android at cab0f17c373e6830c750c6f289d059c40907f4eb](https://github.com/kimjisub/unipad-android/tree/cab0f17c373e6830c750c6f289d059c40907f4eb/app/src/sharedTest/assets/audio-safety).
The binary files, `cases.json`, and `README.md` are byte-for-byte copies.
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
