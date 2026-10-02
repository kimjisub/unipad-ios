# Synthetic-pack UI execution without product changes

This test-only overlay runs unchanged AP-001 from the existing 20-pack conformance
sample on iOS baseline `5dd4cac10f3ede280c9f5207e949a46b624c297f`. It does not
change the fixtures, their expected results, the product, or the original branch.
Only `unipadUITests/PlayPadLayoutTests.swift` in a scratch archive is replaced.

The old test searches for ` - ` in a title. AP-001's actual title is `Conformance`.
`check_selection.py --legacy` reproduces that failure with the original ZIP.
The overlay requires exactly one matching title within `main.packList`, taps it,
then taps **Play**. Scoping to the list avoids the duplicate title in the recent
pack card after a previous run.
This route requires the existing shared UniPack library. Title navigation tries
one upward swipe; a fixture outside that reach fails rather than being reported
as played. Empty-library setup and general long-list navigation are outside this
AP-001 route.
It does not use a URL or bypass the system confirmation dialog. Stage one fixture
at a time because the sample packs share titles. Direct file staging tests the
player entry path; it does **not** verify ZIP import.

The first pad uses the existing `playPadGrid` frame and the product's square-cell
centering calculation for four rows and three columns. The existing Feedback light and Trace Log options are enabled first so the
recording and trace dot show that the canvas received the input. A two-second press sends
both touch-down and release. Then **Menu → Autoplay** starts the sequence;
the player must remain available. AP-001 ends in 900 ms and removes its
transport controls before XCTest can query them after waiting for app idle.
Review the video for these transient controls and chain changes. **Menu → Quit** must return to `main.packList`
and remove `playPadGrid`. Screenshots and accessibility trees are XCTest
attachments. The video records the held pad and the short autoplay sequence.

## Reproduce

Use this issue branch, the original AP-001.zip from the parent evidence, and the
real machine environment on **every** shell invocation. Borrow only through the
harness and use exactly the returned UDID. Do not use `booted`, enable parallel
simulator testing, or launch any other test suite.

Archive the baseline under the current run's scratch directory (refuse to reuse
an existing directory):

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 - <<'PY'
import io, os, pathlib, subprocess, tarfile
source = pathlib.Path(os.environ['PAPERCLIP_RUN_SCRATCH_DIR']) / 'baseline'
source.mkdir()
archive = subprocess.check_output(['git', 'archive', '5dd4cac10f3ede280c9f5207e949a46b624c297f'])
tarfile.open(fileobj=io.BytesIO(archive)).extractall(source, filter='data')
PY
```

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 "$HARNESS/devices.py" up-ios
```

Build the unmodified baseline first to preserve its app and runner fingerprints.
Replace `<lent-udid>` with the printed identifier:

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && xcodebuild build-for-testing \
  -project "$PAPERCLIP_RUN_SCRATCH_DIR/baseline/unipad.xcodeproj" \
  -scheme unipad -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=<lent-udid>' \
  -derivedDataPath "$PAPERCLIP_RUN_SCRATCH_DIR/build" CODE_SIGNING_ALLOWED=NO
```

Run the regression with `<original-AP-001.zip>` set to the existing evidence
file. The legacy run **must fail**; the exact-title run must pass:

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/ios-conformance-ui/check_selection.py '<original-AP-001.zip>' --legacy
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/ios-conformance-ui/check_selection.py '<original-AP-001.zip>'
```

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/ios-conformance-ui/run.py \
  --udid '<lent-udid>' --source "$PAPERCLIP_RUN_SCRATCH_DIR/baseline" \
  --derived-data "$PAPERCLIP_RUN_SCRATCH_DIR/build" \
  --pack '<original-AP-001.zip>' --out "$PAPERCLIP_RUN_SCRATCH_DIR/evidence/run-1"
```

`run.py` compares the entire 236-file baseline archive by path and bytes, including
all 149 files under `unipad/`, bundled themes, project configuration and test
support. It rejects additions, deletions, changes and symbolic links before
building, and refuses an empty baseline list. The only allowed change to a baseline
file is
`unipadUITests/PlayPadLayoutTests.swift` with exactly this tool's overlay bytes;
the original baseline file is also accepted on the first run. Xcode-generated
regular files are allowed only at these exact paths under
`unipad.xcodeproj/project.xcworkspace/`: `xcshareddata/swiftpm/Package.resolved`,
`contents.xcworkspacedata` and `xcshareddata/IDEWorkspaceChecks.plist`. This permits
the baseline build above and subsequent overlay reruns. If any of these paths is
tracked in the baseline, it is still compared by bytes; symbolic links and all
other added files (including source beside generated files) are rejected.
No other overlays are allowed in the source archive. Keep derived data and
output in separate directories. The receipt's `unchangedProductFiles` counter
now counts the full 236-file archive (including the validated overlay), rather
than only the 149 files under `unipad/`.
It requires a fresh output directory to avoid reusing stale recordings, builds the overlay,
records the app and runner SHA-256 values, installs without opening the app,
preserves the existing library by path and hash, stages the unchanged fixture,
records video, and executes only the new test with parallel testing disabled, code coverage disabled, and verbose failure
diagnostics disabled. The UI command has a three-minute timeout.
Its cleanup terminates the app, removes only its successfully created fixture,
resolves the current app data container again (Xcode can relocate it),
compares all pre-existing library hashes, and calls `devices.py down` even when
pack validation, UI execution or recording fails. Recording finalization has a
30-second timeout followed by forced recorder termination; the remaining cleanup
steps and receipt save are attempted independently. Missing/empty video or a
nonzero recorder exit is a failure. `receipt.json` records execution and cleanup
errors and device return after those steps finish. If the current app container
cannot be resolved, the fixture is preserved for inspection and the run fails;
it never guesses a deletion path. If a failure occurs before starting `run.py`, return the device
with the same harness command. Never overwrite an existing Conformance fixture.
If output-directory setup itself fails, the tool still attempts app termination
and device return but cannot save a receipt there; read its nonzero exit and error.

Run the device-free regression checks before borrowing a device:

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/ios-conformance-ui/check_runner.py
```

These checks use fake external commands and run-owned temporary files to cover
Xcode-generated files after a baseline build and on overlay reruns,
source/theme additions, deletions and changes, project/overlay changes, symbolic
links, exact-overlay reruns, empty baseline lists, folder collisions, missing packs, fixture extraction
and UI command failure, recorder launch/exit/timeout/missing-video failures,
container lookup failure and device-return failure. They do not launch an app.

Export readable XCTest attachments before the run scratch directory expires:

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && xcrun xcresulttool export attachments \
  --path "$PAPERCLIP_RUN_SCRATCH_DIR/evidence/run-1/result.xcresult" \
  --output-path "$PAPERCLIP_RUN_SCRATCH_DIR/evidence/run-1/attachments"
```

Upload the evidence to the issue. Do not rely on temporary local paths for handoff.

## Record separation and limits

The single test's setup sets `UITestSupport.englishLaunchArguments()` **before**
`app.launch()`. On this baseline the helper includes
`-UniPadFirebaseLocalOnly YES`. This is a Debug build: `FirebaseRuntime.isLocalOnly`
reads that launch argument before SDK initialization. `AppDelegate` skips
`FirebaseApp.configure()`, and `FirebaseManager` uses local analytics, crash,
messaging, and remote-config stubs. Calling `configureOnAppLaunch()` then calls
those stubs, including its crash collection setter. There is no SDK initialization
followed by a later collection toggle. Existing Firebase files are not deleted or
claimed to be empty. Their queued data is not uploaded by an unconfigured SDK.
Every rerun uses the same launch arguments; do not replace this installation
with a collection-enabled build while local test data remains.

This route does not open Store or download content. The local-only mode is not a
claim that all possible app network requests are blocked: the existing store
reader remains a live implementation. Device settings are not changed.

Passing this route proves UI entry, touch delivery, autoplay activation and exit.
Review the recording to distinguish a visible hold/release and sequence progress
from merely selecting a mode. It does not prove sound, timing, every command,
LED conformance, ZIP import, physical Launchpad behavior, or iOS 17/18 support.
AP-001 has no LED commands, so LED sequence checks are not applicable. Do not
mark the repeating-sound sample KS-003 passed before the separate stop fix is
verified. The parent device tester continues the original 20-pack/60-row comparison.
