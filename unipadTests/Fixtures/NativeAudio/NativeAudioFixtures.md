# Native audio comparison fixtures

These small audio fixtures compare structural inspection with Core Audio decoding.
They are separate from the shared audio-safety corpus.

`ssnd-first.aiff` contains 13,230 mono PCM frames at 44.1 kHz with `SSND` before
`COMM`. Chunk order must not change its structural frame count.

The other six fixtures contain G.711 A-law/mu-law WAV, AAC/ALAC/IMA4 CAF, and
mu-law AIFC. Core Audio on macOS decodes each to 13,230 frames. The inspector's
current `INVALID_FORMAT` result records a known coverage gap. Shared format
coverage must be resolved while preserving existing playback support before
integrating the inspector into pack loading. Native decoder support on an iOS
device is a separate verification requirement.
