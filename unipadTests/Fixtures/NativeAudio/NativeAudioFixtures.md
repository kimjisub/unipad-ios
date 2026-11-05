# Native audio comparison fixtures

These G.711 A-law and mu-law WAV fixtures compare structural inspection with Core
Audio decoding. They are separate from the shared audio-safety corpus.

Core Audio on macOS decodes each to 13,230 frames. G.711 WAV is deliberately outside
the shared format contract: the Android, iOS and web inspectors all accept only PCM,
IEEE float and MPEG data in a WAV, and no collected pack uses G.711. The inspector's
`INVALID_FORMAT` result is therefore the expected answer, and pack loading reports
such a sound as a file that cannot be read. It is never handed to the native decoder
and never counted as a decode failure (`SoundSelectionLoadingTests`). Accepting G.711
later means changing all three inspectors and the shared corpus together.
