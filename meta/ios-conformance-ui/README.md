# Synthetic-pack UI execution without product changes

This test-only overlay runs the unchanged 20-pack conformance sample on iOS
baseline `5dd4cac10f3ede280c9f5207e949a46b624c297f`. Only
`unipadUITests/PlayPadLayoutTests.swift` in a disposable source archive is
replaced. Product code, fixture bytes and expected results stay unchanged.

`pack-fingerprints.json` contains the original ZIP SHA-256 values. Unknown or
modified ZIPs are rejected before building. `baseline-fingerprints.json`
contains the 236 tracked baseline paths and SHA-256 values, allowing the tool
to run from a copied folder outside a git repository. Source additions,
deletions, changes and symbolic links are rejected before any build or launch.
The baseline UI file and this exact overlay are allowed. Only these untracked
regular Xcode-generated workspace files are additionally permitted:

- `unipad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `unipad.xcodeproj/project.xcworkspace/contents.xcworkspacedata`
- `unipad.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist`

Tracked files at those paths still undergo fingerprint comparison. Source and
build directories must be inside the run scratch directory; output may be
elsewhere but must be a new directory, separate from source and build.

## Selection and input

Stage one sample at a time because most titles are shared. Metadata decoding
matches the baseline: case-insensitive filenames, UTF-8/BOM-marked UTF-16,
EUC-KR/CP949, trimmed keys and values, and JSON fallback. The last valid title
wins. Unreadable metadata stops preparation. An existing identical title
(including an empty title) stops before staging. After extraction the title
must still match exactly, and there must be one matching pack.

The UI target receives the parsed title, sample ID and autoplay-file presence
through the copied `.xctestrun` environment. Nonempty titles are selected by an
exact label scoped to `main.packList`; duplicate labels fail. The list waits for
its first load, drags with overlapping screens, retries lost drags and has a
40-drag limit. Both match conditions use the same search, stall tracking and
failure record. Empty title and producer text are omitted from accessibility.
The blank card is identified by its two LED/AUTOPLAY indicator labels and the
absence of other text in that row. Preparation rejects a second empty-title
pack, and UI selection rejects multiple matching blank rows.

The test selects the card, taps Play, captures and accepts any warning, then
enables Feedback light and Trace Log. All approved samples use four rows and
three columns, so pad input uses the product's square-cell centering calculation.
The first pad is held for two seconds and released. KS-004 and KL-004 receive
three presses. The video preserves the held state and transient LED changes.
INF-002 additionally records all 24 chain positions and taps each visible button,
preferring its centre or the midpoint of its visible rectangle when clipped.
Areas smaller than one point in either dimension are recorded without tapping
to exclude floating-point slivers at the window edge. Screenshots require
review: a tap alone does not prove chain selection or an unobstructed target.

If the menu offers Autoplay, the test starts it and captures the player before
and two seconds later. AP-001 also captures ten seconds later to distinguish
completion from a transient or stale screenshot. If it is absent and the ZIP has no autoplay file,
the step is recorded as skipped. A missing item for a ZIP with an autoplay file
fails after the original five-second wait; packs without that file wait two
seconds. Menu → Quit must return to `main.packList` and remove `playPadGrid`.
Screenshots and accessibility trees are retained XCTest attachments.

## Run

Borrow an iOS simulator using the device harness, use exactly its returned UDID,
and create a baseline archive and separate build directory. Build the baseline
before the first overlay run if pre-overlay app/runner fingerprints are needed.

```sh
python3 check_runner.py
python3 check_selection.py /path/to/AP-001.zip
python3 run.py \
  --udid '<lent-udid>' --source '<run-scratch>/baseline' \
  --derived-data '<run-scratch>/build' --pack /path/to/INF-001.zip \
  --out /path/to/fresh-evidence/INF-001 --keep-device
```

The caller supplies the machine environment and run scratch variables. For a
batch, `--keep-device` leaves device return with the caller on both success and
failure. App termination, owned-fixture cleanup, library verification and the
receipt are still attempted independently. The caller must return its borrowed
devices after the batch. Without the flag the tool invokes `devices.py down`.

The tool builds the overlay, fingerprints the app and UI runner, installs without
opening the app, fingerprints every existing library file, and stages only the
unchanged sample. It never overwrites a fixture directory or shared pack.
It records video and runs only
`unipadUITests/PlayPadLayoutTests/testSyntheticPackInputAutoplayAndExit`, with
parallel testing and coverage disabled. The UI command timeout is 420 seconds.
Every run requires a fresh output directory.

A copy of the newly built `.xctestrun` changes all target capture formats to
`screenshots`. XCTest's own recording caused SimRenderServer crashes during
teardown on the baseline; the separate `simctl io recordVideo` supplies the
walkthrough. The original built file is unchanged. The receipt records original
and copied file hashes, formats, target parameters and all commands.

Cleanup terminates the app, resolves its current data container again (Xcode can
relocate it), removes only the directory successfully created by this run, and
compares every original library file's hash. If the current container cannot be
resolved, it preserves the staged fixture instead of guessing a deletion path.
A library difference is a failure. `receipt.json` records execution and cleanup
errors, library preservation and whether device return was deferred.

Recording stop waits up to 30 seconds, then kills a hung recorder. A finalized
movie with frames and a positive-duration movie header can still be used after
that known recorder hang. Empty, cut-off or unfinalized movies fail. The receipt
records the duration, hash, byte count, exit code and hang state.

Export readable screenshots and trees before temporary results expire:

```sh
xcrun xcresulttool export attachments \
  --path /path/to/evidence/result.xcresult \
  --output-path /path/to/evidence/attachments
```

Preserve each round's command, output, result bundle, receipt and source commit
before rerunning. Do not replace a failed round with a later round's files.

## Device-free checks and limits

`check_runner.py` covers source fingerprints, permitted generated files,
approved ZIP rejection, arbitrary/empty titles, duplicate titles and metadata
encodings, stale output rejection, execution outside git, target parameters,
optional device return, extraction/build/UI failures, recorder failures, library
restoration and receipt saving. External device commands are faked; these checks
do not launch the app. `check_selection.py` models lazy-list ordering, first-load
waits, lost drags, duplicate titles and the drag limit, and checks the overlay's
search ordering. It is a model, not accessibility or device evidence.

The test calls `UITestSupport.englishLaunchArguments()` before `app.launch()`.
The baseline helper includes `-UniPadFirebaseLocalOnly YES`: its Debug runtime
uses local Firebase stubs without configuring the SDK. Queued Firebase files are
not deleted. Local-only mode does not block every possible network request;
the existing store reader remains live. The test never opens Store or downloads
content and does not change simulator settings.

Direct staging tests player entry, not ZIP import. Successful execution proves
entry, touch delivery, optional autoplay activation and exit. Review captures
and video for warning text, chain selection, press/release and LED colors. It
does not by itself prove sound, timing, command conformance, physical Launchpad
behavior, audio latency, interruption recovery, or iOS 17/18 support. Samples
without LED or autoplay commands are recorded as not applicable for those checks.
