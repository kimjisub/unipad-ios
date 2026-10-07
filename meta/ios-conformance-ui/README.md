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
This route requires the existing shared UniPack library. Starting at the top,
title navigation checks the exact-title count at each step and scrolls upward until
the title is hittable. Reaching 40 swipes fails even if the title is then visible.
Two or more matches at any
step fail immediately. Each step drags from 80% to 25% of the list height and holds
0.3 s before lifting, so the list stops under the finger: consecutive screens
overlap and no card is flung past between checks. The end of the list is the
guiding actions row (`main.guide.download`), which follows the last pack card;
when it is hittable and the title is not, the title is missing. A drag that leaves
the list where it was is retried and still counts toward the 40-swipe limit; it is
never taken as the end. (On iOS 26.3.1 in landscape, one quick `swipeUp()`
left a seven-pack list unmoved and the previous rule, unchanged visible labels
after a swipe, reported the end of the list. The same swipe moved the list in a
later run, so the loss is intermittent.) The list exists while its first load
is still running, holding only the guiding actions row, so the search first
waits up to 30 s for a label above that row (a pack card); without one it fails
as "no pack cards" instead of taking the empty list as its end. Immediately before
selection the count must still be exactly one and the title must be hittable.
One `CONFORMANCE title-search swipes=<n> stalls=<n> counts=<...>` line records the
search; `stalls` counts drags after which the list's first label and its position
were unchanged. The line is printed before selection and before each failure
(no pack cards, duplicate titles, 40-swipe limit, end of list). It is not printed from `defer`:
with `continueAfterFailure` off, `XCTFail` stops the test and skips `defer`, so
failed runs lost the line. At the end of the list, a single title that is present
but not hittable fails as "not hittable" rather than "missing".
Empty-library setup remains outside this AP-001 route.

This is a **different tool** from original tool commit
`e7192306099da3d7dee5a0c675921f477ccce9c4`: the original asserted count one before
scrolling and tried at most one swipe. The new ordering supports long lists
whose off-screen cards are not yet created. Preparation now reads each immediate
pack folder's title before staging and checks again after staging; this catches
duplicate titles even when their cards cannot appear on the same screen.
Selection through Quit is unchanged.
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
file. The legacy run **must fail**; the exact-title and ordering-model run must pass:

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

The UI test runs from a copy of the built `.xctestrun`, not from the scheme. On
this baseline every test target there has `PreferredScreenCaptureFormat =
screenRecording`: XCTest records the screen itself, and when it stops that
recording twice the Mac's `SimRenderServer` crashes and CoreSimulator shuts the
simulator down. A run on iOS 26.3.1 passed its test, then lost the device: the
UI command hit its timeout, the walkthrough was empty and the fixture stayed in
the library. `-collect-test-diagnostics never` does not stop that recording.
After the overlay build, `run.py` requires exactly one `.xctestrun` in
`<derived-data>/Build/Products` written by that build (every build-for-testing
rewrites its file; one left by an earlier build for another destination, such as
`generic/platform=iOS Simulator`, is older and ignored), writes `conformance-screenshots.xctestrun`
beside it (`__TESTROOT__` is that folder) with every test target set to
`screenshots`, and runs:

```sh
xcodebuild test-without-building \
  -xctestrun '<derived-data>/Build/Products/conformance-screenshots.xctestrun' \
  -destination 'platform=iOS Simulator,id=<lent-udid>' -derivedDataPath '<derived-data>' \
  -parallel-testing-enabled NO -enableCodeCoverage NO -collect-test-diagnostics never \
  -only-testing:unipadUITests/PlayPadLayoutTests/testSyntheticPackInputAutoplayAndExit \
  -resultBundlePath '<out>/result.xcresult' CODE_SIGNING_ALLOWED=NO
```

The built `.xctestrun`, product files, app and runner are not changed; failure
screenshots remain XCTest attachments, and the walkthrough still comes from
`simctl io recordVideo`. The receipt records the built file's name and SHA-256,
its capture formats before the change, and the copy's SHA-256. A missing,
second or target-less `.xctestrun` from the overlay build stops before recording
and UI execution.
Before staging, titles are read from every immediate directory under
`Documents/UniPack` with the baseline's metadata rules: case-insensitive `info`
filenames, UTF-8 (optional BOM), BOM-marked UTF-16, EUC-KR or CP949, trimmed
lines/keys/values, and the product's line-splitting rule: leading empty `=`
components do not count toward the one-split limit, further `=` characters stay
in the value, and an empty trailing value is ignored. The last valid `title`
value wins.
When no `info` file exists, `info.json` supplies its string `title`. An unreadable
metadata file stops preparation rather than guessing. An existing exact
`Conformance` title stops before the fixture is created. This exact product-title
check replaces the original raw `title=Conformance` substring refusal. Other titles
such as `Conformance 2` and `ConformanceX`, or an earlier `title=Conformance` line
overridden by a later `title=Other` line, are allowed. After extraction, exactly
one product-parsed `Conformance` title is required before recording or UI tests.
Its cleanup terminates the app, removes only its successfully created fixture,
resolves the current app data container again (Xcode can relocate it),
compares all pre-existing library hashes, and calls `devices.py down` even when
pack validation, UI execution or recording fails. Recording finalization has a
30-second timeout followed by forced recorder termination; the remaining cleanup
steps and receipt save are attempted independently. The video must be a
finalized movie: top-level boxes that end exactly at the end of the file, frames
(`mdat`) and a movie header (`moov/mvhd`) with a positive duration, which the
receipt records as `recordingSeconds`. A missing, empty, cut-off or unfinalized
video, or a nonzero recorder exit, is a failure. On 2026-10-07 `simctl io
recordVideo` (CoreSimulator 1174.9.2) wrote a finalized movie on SIGINT and then
never exited, in this tool and on its own with no test running; on 2026-10-02 it
exited 0. When the recorder is still running 30 seconds after SIGINT it is
killed, `recordingHungAfterStop` is true, `recordingExitCode` is -9, and the run
passes only if the finalized-movie check passes. The killed recorder can leave a
`walkthrough.mp4.sb-*` temporary file beside the video; review `walkthrough.mp4`.
`receipt.json` records execution and cleanup
errors and device return after those steps finish. If the current app container
cannot be resolved, the fixture is preserved for inspection and the run fails;
it never guesses a deletion path. If a failure occurs before starting `run.py`, return the device
with the same harness command. Never overwrite an existing Conformance fixture.
If output-directory setup itself fails, the tool still attempts app termination
and device return but cannot save a receipt there; read its nonzero exit and error.

The normal `check_selection.py` run models a list that creates only the current
screen's labels and shows the guiding row only on its last screen. It covers the
original pre-scroll failure, the new order,
35 swipes, success at 39 swipes and rejection at 40, duplicate titles on the first
or a later screen, a missing title at
the list end, and the 40-swipe limit. A swipe can be marked as lost (the list does
not move): with the iOS 26.3.1 landscape screens and the first swipe lost, the previous
unchanged-labels rule fails with "end of pack list" while the new order retries and
selects; a list where every swipe is lost stops at the 40-swipe limit. The previous
model let every swipe move the list until its last screen, so it could not express
that failure. A first load that shows only the guiding row for a few checks
makes the previous order (search as soon as the list exists) fail with "end of
pack list"; the new order waits and selects, and fails as "no pack cards" when
cards never arrive. Source guards also require the search record before every failure and before the
selection-time recheck, require the wait for pack cards before the search,
and reject a record printed from `defer`. `--overlay <path>` checks the ordering guards
against a different Swift overlay, including the original for a failing base
check. These are **ordering-model checks, not device evidence**; they do not
execute XCTest or prove accessibility visibility or hittability.

Run the device-free regression checks before borrowing a device:

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/ios-conformance-ui/check_runner.py
```

These checks use fake external commands and run-owned temporary files to cover
Xcode-generated files after a baseline build and on overlay reruns,
source/theme additions, deletions and changes, project/overlay changes, symbolic
links, exact-overlay reruns, empty baseline lists, folder collisions, missing packs, fixture extraction
and UI command failure, recorder launch/exit/timeout/missing-video failures, a recorder that hangs
after a finalized movie (accepted) or a cut-off one (rejected), cut-off movies,
version-1 movie headers,
container lookup failure and device-return failure, and the screenshots
`.xctestrun` copy (command, unchanged original, reruns, an older file from another
destination, and a missing, second or empty file from the overlay build). They do not launch an app.
They also check duplicate titles in differently named folders, spaced keys,
uppercase metadata filenames, JSON titles, BOMs and legacy encodings,
unreadable metadata, and a wrong title after extraction. The three other-title
cases above must reach UI execution and preserve the library after cleanup.
Each rejection verifies
preserved existing files, no UI execution, and device return. `--runner <path>`
runs the same checks against an archived runner for a failing base check.

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
