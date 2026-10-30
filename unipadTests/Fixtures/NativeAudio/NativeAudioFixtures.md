# Native audio comparison fixtures

These G.711 A-law and mu-law WAV fixtures compare structural inspection with Core
Audio decoding. They are separate from the shared audio-safety corpus.

Core Audio on macOS decodes each to 13,230 frames. The inspector's current
`INVALID_FORMAT` result records a known coverage gap. Shared format coverage must be
resolved while preserving existing playback support before integrating the inspector
into pack loading. Native decoder support on an iOS device is a separate verification
requirement.
