# Native grammar evidence

`native_grammar_mapping.json` is the expectation-to-test table. It supplements the
shared unpacked-pack corpus with real ZIP imports, case-sensitive filesystem
reads, and real audio rendering. It does not change the grammar or shared tools.
A-01 and A-02 remain owned by the shared iOS run and are not counted twice here.

| Rule | Native evidence | Expected result |
| --- | --- | --- |
| F-01 | `UniPackRootNameTests` | A probe in the actual test directory cannot read a differently cased path. All five uppercase root names load real metadata, sounds, LED events and autoplay. `info.txt` and `keySounds` cannot replace required files. |
| F-05 | `UniPackArchiveLayoutTests`, `ExternalFileImportTests.testPackFolderBesideAReadmeImports` | Wrappers, adjacent files, Finder metadata and unrelated folders do not hide the one pack. The normal external-file import route succeeds too. Ambiguous two-pack archives fail. |
| F-06 | `UniPackArchiveNameTests` | Raw ZIP bytes cover UTF-8 with its flag, valid UTF-8 without its flag, and non-UTF-8 CP949 without its flag. Real import resolves the same Korean sound name, sound bytes and engine playback. File contents stay UTF-8; this is not a text-content encoding test. |
| A-03 | No native OGG tests in this source revision | Unverified. A decoder and valid/corrupt OGG tests must land before a later mapping can confirm the rule. No decoder is added here. |
| A-04 | `SoundEngineDecodingTests.anM4ASoundPlays` | Actual AAC/M4A decoding and playback produce nonzero PCM at the engine's mixer. |
| A-05 | `SoundEngineDecodingTests.mp3DataInAFileNamedWavPlays` | Actual MP3 bytes in a `.wav` file decode by content and render nonzero PCM at the engine's mixer. |

The mixer observation is a test-only reflection of the existing private
AVAudioEngine; changing that field makes the observation fail explicitly.
It measures software output, not physical speaker delivery. The PCM fixtures
already used by these tests are retained.

Run on a simulator already allocated by your device manager. Provide an existing
case-sensitive APFS directory accessible to that simulator's test host. The tests
probe it themselves; a host volume label alone cannot confirm F-01. Without an
explicit directory the root-name suite is skipped, so ordinary CI on a
case-insensitive filesystem never claims to verify it.

```sh
python3 ci/run_native_grammar.py \
  --udid "$SIMULATOR_UDID" \
  --case-sensitive-root "$CASE_SENSITIVE_ROOT" \
  --derived-data "$DERIVED_DATA" \
  --out "$FRESH_ATTEMPT_DIRECTORY" \
  --grammar-version "$GRAMMAR_VERSION" \
  --grammar-revision "$GRAMMAR_REVISION"
python3 -m unittest discover -s ci -v
```

The runner builds with warnings treated as errors, then runs all unit tests and
`ExternalFileImportTests.testPackFolderBesideAReadmeImports`, without parallel
execution or automatic retries.
Test results and explicit attachments are retained; automatic simulator-wide
diagnostic collection is disabled, including for intentional mutation failures.
`--only-testing` can select smaller mutation checks; every missing linked test
then remains unverified. It does not allocate or stop devices or create volumes.
Keep each attempt's directory and archive it before starting another attempt.
Use `--purpose baseline` for unchanged product sources, or `--purpose mutation
--mutation-description "..."` for an intentional defect. These attempts stay
separate from normal verification evidence.

Each directory contains the build and test commands and exit codes, repository
commit and source diff hash, source patch, Xcode/host version, configured
xctestrun hash and file, raw `.xcresult`, exported test tree, and `ios-native.json`.
Input fixture/source hashes and the shared corpus hash bind the expectations to
the executed revision. The native rules do not use that corpus; their separate
ZIP, filesystem and audio evidence is explicit. If the full unit suite runs the
existing shared harness, its unchanged report is saved under `shared-conformance`.
The raw result digest hashes sorted relative UTF-8 paths followed by a NUL byte
and each file's binary SHA-256 digest. Upload receipts can bind that digest to
an attachment without editing any test outcome.
The test tree supplies the actual device and OS. Reports are generated only from
xcresult, never from a manually assigned pass or an optimistic log match.
Every mapped test must be present and passed, including argument and repetition
results. Skips, expected failures, missing tests, unknown environments and failed
attempts cannot confirm a rule. Preserve every attempt: a later pass does not
erase an earlier failure. OGG remains unverified in successful runs.

The JSON format is a local versioned proposal (`schemaVersion: 1`), with grammar
version and revision supplied at execution time. A shared report adapter can
consume it later; this runner does not modify the shared corpus or its report.
