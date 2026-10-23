# Original sound entry observations

`sound-identity-corpus.json` is a frozen observation input from
[unipad.io commit 69881749822aace4d2af9ebe9b67659421fc8f48](https://github.com/kimjisub/unipad.io/commit/69881749822aace4d2af9ebe9b67659421fc8f48).
It has 269 cases and SHA-256
`5b68771853a6f328ee3443c173953499b25d407f43b00d16b25d4a1c96719678`.
Its checksum file retains the upstream `corpus.json` filename. The existing
214-case `corpus.json`, checksum, and observations remain unchanged. This is
an observation snapshot, separate from synchronization of the shared corpus.

`SoundIdentityObservationTests` runs exactly KS-G601 through KS-G604 and
KS-G620 through KS-G625. Enable it explicitly with
`TEST_RUNNER_UNIPACK_SOUND_IDENTITY_OBSERVE=1` and select
`-only-testing:unipadTests/SoundIdentityObservationTests` in an ordinary
`xcodebuild test` invocation. Set `TEST_RUNNER_UNIPACK_CONFORMANCE_OUT` to an
empty evidence folder for each run. Reports always mark this observation as
partial, including when no case-prefix variable was supplied. A nonzero
exit code and the individual failures are part of the baseline evidence.

To observe another disk, set `TEST_RUNNER_UNIPACK_SOUND_IDENTITY_ROOT` to an
existing writable folder on that volume. Archive, staging, and imported
library all live there. A per-case probe reports the file-system format,
whether letter case distinguishes files, and whether canonical Unicode
spellings distinguish files. The format can be `unknown` under the iOS SDK;
retain the host volume description separately. Diagnostics also record the
actual import root and whether alias paths can read the probe bytes. An inaccessible volume is a failed observation,
not a reason to use another folder silently.

The harness builds a stored UTF-8 ZIP, reads its original names and payload
hashes from the ZIP bytes, and calls `UniPackImporter.importPack`. It then loads
the published pack and uses `soundGet` to inspect each queue item selected for
the sound engine. The selected file's actual bytes and relative path must
identify exactly one original entry. Neither expected results nor expected
asset names participate in that lookup. Missing or ambiguous provenance is
unverified. Lost source contents fail even if the chosen sound happens to match.

`ios.json` carries `archiveEntry`, `sha256`, `loop`, and `wormhole` in each
sound queue. Separate `*-identity.json` diagnostics retain the raw archive
manifest, stored names and hashes, selected storage paths and hashes, lost
contents, and disk probe. Storage normalization alone does not fail a case.
JSON comparison preserves original Unicode spelling rather than using Swift's
canonical String equality.

`SoundIdentityTests` checks wrong entries, wrong bytes, overwritten contents,
ambiguous provenance, and independence from expectations. These checks run in
the normal unit suite. They do not assert that every observation passes on the
current app. No app extraction, parser, or playback logic is changed. The
observed boundary ends at the file bytes selected for the sound engine; it does
not establish decoded audio or speaker output.
