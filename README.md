# UniPad iOS

<a href="https://apps.apple.com/app/id6760479102">
  <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83" alt="Download on the App Store" height="50">
</a>

If the store page doesn't open in your country, you can play in your browser at https://unipad.io/play.

UniPad is a performance-based rhythm game that enables connection with a launchpad and allows users to create their own beatmaps using the unique "unipack" format, fostering creativity and sharing within the community.

## Features

- **UniPack Support**: Load and play custom UniPacks (.zip / .unipack) with sound mapping, LED animations and autoplay sequences.
- **Launchpad & MIDI Support**: Works over USB with automatic detection for:
  - Novation Launchpad S, Mini and MK2
  - Novation Launchpad Pro (Stock firmware)
  - Novation Launchpad Pro (mat1jaczyyy Performance CFW)
  - Novation Launchpad (CoreFW)
  - Novation Launchpad X, Mini MK3 and Pro MK3
  - Midi Fighter 64
  - Mystrix
  - Generic Master Keyboard
- **Custom Themes**: Supports custom skins, pad textures, phantom overlays, chain LEDs and background artwork.
- **Low-Latency Audio**: Multi-channel sound playback built for live performance.
- Built with SwiftUI, SwiftData and CoreMIDI.

## Sound formats

Ogg sounds can contain either Vorbis or Opus audio. Both are decoded locally,
including on iOS versions without native Ogg support. WAV, MP3 and AAC sounds
continue to use the system decoder. M4A files containing Opus use the built-in
Opus decoder when the system cannot read their audio packets.

## Getting Started

### Prerequisites

- macOS with Xcode 15.0 or later
- iOS / iPadOS 17.0+ device or simulator

### Setup

1. Clone the repo:
```bash
git clone https://github.com/kimjisub/unipad-ios.git
cd unipad-ios
```

2. Open the Xcode project:
```bash
open unipad.xcodeproj
```

3. Select your target device or simulator and hit **Run** (`Cmd + R`).

## Pull request checks

Every pull request runs two independent jobs in **iOS checks**, each on a
GitHub-hosted `xcode-27` runner with Xcode 27.1, the same Xcode used for local
checks and release builds; an older Xcode accepts and rejects different
concurrency code, so a check that passes locally could fail here.

- **Build and unit tests** runs the `unipadTests` target in Debug on an iPhone
  simulator whose iOS version the selected Xcode supports
  (`ci/pick_simulator.py`), preferring iPhone 17 Pro like local checks, on the
  newest supported iOS that has it. UI tests are excluded. It uses `unipad-ci`,
  which runs the complete unit test target without attaching a debugger,
  collecting unused code coverage or building the UI test runner. The `unipad`
  scheme keeps interactive debugging
  and the existing unit and UI test plans.
- **Release build and tool tests** runs the tests of the scripts in `ci/`,
  builds Release for iOS Simulator without signing, and checks that the app's
  open source notices list exactly the Swift packages that build compiled (see
  below). None of this needs a simulator, so it does not spend the unit test
  job's time.

Script tests use `ci/run_tool_tests.py`: each file runs in its own process,
with at most two Swift-compiling files at once and other files filling the
remaining worker slots. Starts and completed results are printed immediately.
Cancellation prints unfinished names and partial output before terminating and
reaping owned children. Counts come from separate result files, so diagnostics
cannot change them. A failing file, empty file, missing result or count mismatch
fails the job.

Both jobs have a 30-minute limit and neither waits for the other. Dependencies
use the committed `Package.resolved` versions.

The unit tests are built first (`build-for-testing`), and only then does
`ci/simulator_settle.py` boot the selected simulator: a simulator booting in the
background slowed dependency resolution and the builds by more than the boot
saved. After its first boot, the simulator's system services (PosterBoard and its
wallpaper extensions among them) keep the runner saturated for minutes, and tests
with time limits that run then fail on time alone. The script reads the CPU time
of the simulator's processes with `ps` and waits until all of them together have
used at most 40 CPU seconds in the last 30 seconds, held for 30 seconds of real
time. The wait ends after at most 6 minutes, or 11 minutes after the job
started, whichever comes first, so that even a build from an empty cache leaves
the tests enough of the job's 30 minutes. Then the tests run without building
again (`test-without-building`). If the simulator's processes cannot be found,
it waits instead for the runner's load average to stay 20% below its peak for 30
seconds. Reaching either limit does not fail the job. The step's first line says
how long it waited and why it ended (settled, or which limit), with the poster
processes' CPU and the runner's load average for comparison. Its second line
names the five busiest simulator processes at that moment. `settle.log` in the
job's results holds every sample.

Each job keeps its build's compilation results between runs in the GitHub Actions
cache (`COMPILATION_CACHE_ENABLE_CACHING`) under its own key, so sources whose
inputs did not change, mostly the Swift packages, are not compiled again. Each
cache is capped at 1.5 GB. The same checks also run after changes are merged
into `main`.

The jobs need no repository secrets or signing credentials. Each replaces the
Firebase plist only in its disposable checkout with clearly fake values from
`ci/firebase_fixture.py`; the existing unit-test runtime uses local Firebase
stubs. App configuration, version, and behavior in normal builds are unchanged.
Logs and the test result bundle are available for seven days in the run's
`ios-check-results` (unit tests) and `ios-release-build-results` (Release build)
artifacts. This workflow does not upload to a store. Branch protection requires
named checks: add **Release build and tool tests** next to **Build and unit
tests** so the Release build stays required.

## UI tests

UI tests are not part of the pull request checks. Run the whole `unipadUITests`
target on an iPhone simulator before pushing a change, and attach the result
to the pull request:

```bash
ci/ui-tests.sh <simulator-udid>
```

The script builds Debug without signing and runs every UI test on that
simulator, one at a time. Its last line is the result, for example
`UI tests: 87 passed, 0 failed, 0 skipped; 87 total; exit 0`. Any failed or
skipped test, or a run without a complete result, gives a non-zero exit. The
log, `UITests.xcresult` and `summary.json` are kept in `build/ui-tests` (set
`UNIPAD_UI_TEST_OUTPUT` to use another folder).

- Use iPhone 17 Pro or iPhone 16e: the layout checks compare against safe areas
  measured independently on those screens.
- Each test launch gets its own library and generates the packs it needs
  (`unipad/App/ReleaseTestSupport.swift`, compiled out of Release builds), so
  packs already on the simulator are neither used nor changed.
- Help checks that need a real Escape key or VoiceOver run through
  `ci/host-keys.sh`, which the script uses. It presses keys through the
  simulator's HID input with a pinned, checksum-verified AXe release. VoiceOver
  checks need Xcode 27 and iOS 27. The English and Korean help checks share
  one VoiceOver session while relaunching the app in each language, including
  successful test repetitions. Failed tests and suite teardown clean up the
  enabled service. The injected test probe accepts an opt-in local notification
  to activate only the Settings, reconnect and help buttons through their public
  accessibility actions. This keeps setup within MIDI selection's five-second
  automatic confirmation window while VoiceOver stays on. Escape continues to
  use the simulator's hardware input and the app's own event handling.
  `host-keys.sh` saves the simulator's VoiceOver automation events in
  `voiceover-automation.log` beside the result bundle (or beside derived data
  when no bundle is specified), even when the tests fail. Collection errors
  and the collection exit code are saved in `voiceover-automation-collection.log`.
- The script leaves out, by name, the checks it cannot set up, and lists why in
  `ci/ui-tests.sh`: the virtual MIDI round trip (`ci/virtual_launchpad_roundtrip.py`),
  the notification permission round trip
  ([Notification simulator check](#notification-simulator-check)),
  the real-pack LED capture (`UNIPAD_LED_TIMING_VISUAL_PACK`), the real store
  download, iPad pointer input, and iPad window/status-bar checks. The release
  commands below include the virtual MIDI and iPad checks with their setup.
  The notification, live-store and real-pack checks still need separate setup.

- A full run takes about 80–90 minutes. To split it, pass test classes; the
  parts together must name every class:

  ```bash
  ci/ui-tests.sh <simulator-udid> -only-testing:unipadUITests/PackWarningUITests -only-testing:unipadUITests/PlayChainLayoutTests
  ```

## Release feature checks

Run both commands below on simulators acquired through your device harness. Use
an iPhone 17 Pro, release it when its command finishes, then acquire an iPad Pro
13-inch (M5). The iPad model is explicit because the layout checks use safe areas
measured independently on that screen. The commands never acquire, create or
release devices themselves. Use a new output folder for each attempt and keep
derived data outside it so both commands can reuse the build:

```bash
python3 ci/release_checks.py --device iphone --simulator <iphone-udid> \
  --output <scratch>/release-iphone --derived-data <scratch>/dd
# Release the iPhone, then acquire an iPad Pro 13-inch (M5).
python3 ci/release_checks.py --device ipad --simulator <ipad-udid> \
  --output <scratch>/release-ipad --derived-data <scratch>/dd
```

For shorter runs, replace the two commands above with **all five** commands
below, using an acquired simulator of the indicated family. Each stage checks
its own complete results; a successful stage alone does not verify a release.
Keep every output folder. The shared iPad group contains the iPhone plan's UI
checks, and the iPad group contains the additional window, status-bar, pointer
and pad-layout checks. Together they cover the entire iPad plan without overlap.

```sh
python3 ci/release_checks.py --device iphone --stage screen --simulator <iphone-udid> \
  --output <scratch>/iphone-screen --derived-data <scratch>/dd
python3 ci/release_checks.py --device iphone --stage midi --simulator <iphone-udid> \
  --output <scratch>/iphone-midi --derived-data <scratch>/dd
python3 ci/release_checks.py --device iphone --stage roundtrip --simulator <iphone-udid> \
  --output <scratch>/iphone-roundtrip --derived-data <scratch>/dd
# Release the iPhone, then acquire an iPad Pro 13-inch (M5).
python3 ci/release_checks.py --device ipad --stage screen --screen-group shared --simulator <ipad-udid> \
  --output <scratch>/ipad-shared --derived-data <scratch>/dd
python3 ci/release_checks.py --device ipad --stage screen --screen-group ipad --simulator <ipad-udid> \
  --output <scratch>/ipad-additions --derived-data <scratch>/dd
```

When a screen stage is still too long for one device session, replace that
stage with three parts. Run each command below separately for **every** index
`1`, `2` and `3`, on the indicated acquired device. Parts select UI tests only,
so the iPhone parts also need the `unit` stage, which runs the release plan's
unit suites in the same Release build. Keep the MIDI, round-trip and
iPad-additions commands above. All parts must use the same commit:

```sh
python3 ci/release_checks.py --device iphone --stage screen --screen-part <index>/3 \
  --simulator <iphone-udid> --output <scratch>/iphone-screen-<index> --derived-data <scratch>/dd
python3 ci/release_checks.py --device iphone --stage unit \
  --simulator <iphone-udid> --output <scratch>/iphone-unit --derived-data <scratch>/dd
python3 ci/release_checks.py --device ipad --stage screen --screen-group shared --screen-part <index>/3 \
  --simulator <ipad-udid> --output <scratch>/ipad-shared-<index> --derived-data <scratch>/dd
```

Parts select disjoint tests from the plan in a stable order and together cover
the entire requested group. Each part verifies all its selected tests and
records its index, part count and commit in `result.json`. A passing part is
only that part's result; skipped, missing or empty parts do not verify the stage.
A whole iPhone screen stage and the `unit` stage check each unit suite the plan
names by name, so a suite that drops out of the run fails the command.

Stopping a command (Ctrl-C, `SIGTERM`, `SIGHUP`) is passed to the running stage
and every process it started, `xcodebuild` under the stage scripts included. The
scripts then run their cleanup. Only the first stop is passed on, so stopping
again does not cut that cleanup off; whatever has not stopped 45 seconds later is
killed, and nothing a stage started is left running after it ends. `result.json`
then says `interrupted`, and the command exits with 128 plus the signal number.

The iPhone command runs `ReleaseFeatures.xctestplan`, then builds the Debug
virtual-MIDI host and runs `MidiInputPathTests`, `MidiDeviceSelectionTests` and
`VirtualMidiPlayScreenUITests` in one virtual-device session. It also runs both
input orders of `VirtualLaunchpadRoundTripUITests`. The play-screen checks remove
and recreate a virtual Launchpad MK2 twice while play stays open, including a pad
held when unplugged, and require fresh input and returning press/release lights.

The iPad command runs `IPadReleaseFeatures.xctestplan`: every UI test selected by
`ReleaseFeatures`, all `WindowControlsBackButtonTests` and
`StoreBackButtonStatusBarTests`, the pointer click/drag/chain check and
`PlayPadLayoutTests`. It checks the pad grid's centre, space for chains and the
menu, and reachable controls at iPad size. The iPhone-only exclusion list is not
applied to these iPad checks.

Both screen runs use Release with `UNIPAD_TEST_CONDITIONS=UNIPAD_RELEASE_TESTS`
and `ENABLE_TESTABILITY=YES`; a store build sets neither. The virtual MIDI runs
use Debug fixtures and do not establish store-build or physical USB behaviour.
A failed command, skipped test, empty/incomplete result, missing expected UI test,
or unreadable result bundle fails the release command. `result.json` records the
commit and stage commands; logs, raw summaries, test trees and result bundles
remain beside it. A rerun never overwrites an earlier output directory.

To run just the iPhone screen plan while diagnosing a failure:

```bash
UNIPAD_UI_TEST_CONFIGURATION=Release ci/ui-tests.sh <iphone-udid> -testPlan ReleaseFeatures
```

`python3 -m unittest discover -s ci -v` checks the commands' failure handling and
keeps both plans pointing at existing tests. It also prevents the iPad plan from
losing a screen selected by the iPhone plan.

In these builds the store list and pack downloads come from the fixture
answers, which fail every request they do not know instead of reaching a
server. A pass therefore says nothing about the live store and download
servers: features marked "fixture" below are checked against them by hand.

| Feature | Checked by | Not checked on a simulator |
| --- | --- | --- |
| Launch, empty and filled pack list, Settings and back | `HomeCardVisibilityTests`, `HomeSettingsEntryTests`, `SettingsBackNavigationTests`, `MainListReadTests` | |
| Import from a file, the result, opening the pack; share codes are retired, and an old share-code link leaves home as it is without a request | `ExternalFileImportTests`, `ImportResultDialogFlowTests`, `FirstPackGuideTests`, `RetiredShareLinkTests`, `AppRouterDeepLinkTests`, importer unit tests | Another app opening a `unipad://` link |
| Pad sound requests, `keyLed` lights, chain changes, several fingers | `MultiTouchPlayTests`, `MultiTouchPlayUITests`, `PlayChainLayoutTests`, `ChainReleaseTests`, `ChainReleaseUITests`, `LedRunnerTests`, `PlaybackStopTests` | Audible sound and touch latency; several real fingers on screen (synthetic input only) |
| Autoplay start, pause, resume and stop; practice modes | `ReleaseFeatureUITests`, `AutoPlayRelaunchUITests`, `PlaybackStopUITests`, `AutoPlayRunnerTests`, `AutoPlayRelaunchTests`, `StepReturnAutoplayTests` | |
| Launchpad and MIDI: discovery, input, LED output | `LaunchpadCoreCFWDriverTests`, `LaunchpadProCFWDriverTests`, `PlayViewModelLoadTests`, `MidiConnectionHelpTests`; the virtual MK2 round trip below | A physical Launchpad over USB and physical unplugging/replugging |
| Store download (fixture), pack deletion with play history and bookmarks | `StoreDownloadTests`, `StoreDownloadFailureUITests`, `ReleaseFeatureUITests` (download then open), `PackDeletionUITests`, `UniPackDownloaderTests`, `PackDeletionTests` | The live store and download servers |
| Language, theme, rotation, notch and home indicator | `AppLanguageTests`, `LocalizationBundleTests`, `PlayThemeLayoutTests`, `HomeGuidingCardsTests`, `PlayChainLayoutTests`, `PlayLayoutTests` | Language follows the system setting; the app has no language switch of its own |
| Leaving for Home or locking the screen during play, then returning | `AudioLifecycleUITests`, `ReleaseFeatureUITests` (lock), `PlayInterruptionTests`, `SoundEngineInterruptionTests`, `AudioSessionGateTests`, `AutoPlayInterruptionPolicyTests`, `SystemTerminationReporterTests` | Locking a real device with a passcode; phone calls and other apps taking the audio |

For a standalone diagnosis of the virtual Launchpad round trip (already included
in the iPhone release command):

```bash
python3 ci/virtual_launchpad_roundtrip.py --simulator <simulator-udid> --output build/virtual-launchpad --derived-data build/virtual-launchpad/DerivedData
```

Pass `--controller pro` to run the same input round trip with a virtual original
Launchpad Pro. That also requires every mode message and its settling delay to
precede the first pad or round-button light, including light-off messages.

The virtual Matrix check holds an endless pad light, sends a velocity-zero release,
captures the held and released play screen, then checks that leaving play clears all
32 round lights. It records the release before leaving, so an exit clear cannot hide
a failed release:

```bash
python3 ci/matrix_roundtrip.py --simulator <simulator-udid> --output build/virtual-matrix --derived-data build/virtual-launchpad/DerivedData
```

Both commands require a new output directory and a simulator acquired through the
device harness. They do not establish physical USB operation or audible output.

What a simulator cannot show is checked by hand on a device with the release
candidate: connect a supported Launchpad, press two pads together and change
chains while listening, unplug and replug it during play, lock and unlock the
device and switch to another app and back during play, download a pack from the
live store and play it, and open an old share-code link from another app.

## Open source notices

Settings > Open Source License shows every third-party component built into the
app with its full license text. The list is
`unipad/Resources/OpenSourceLicenses/OpenSourceLicenses.json`; each entry names the
license files it is made from, in a resolved package checkout (`pin`) or in a
vendored package (`path`). After adding, removing or updating a package, build
Release once and run:

```sh
python3 ci/open_source_licenses.py write --source-packages <cloned source packages folder>
python3 ci/open_source_licenses.py check --source-packages <cloned source packages folder> \
  --derived-data <derived data folder>
```

`write` regenerates the bundled texts; `check`, which CI runs after its Release build,
fails when a package the build compiled is not listed, a listed one is no longer
built, a version differs from `Package.resolved`, `Vendor/XiphVorbis/vendor.sh` or
`Vendor/XiphVorbis/vendor_opus.py`, or a
bundled text differs from its source.

## Play input checks on a Mac

Before pushing play-input test changes, run the input edge UI checks on an iPhone
and an iPad simulator, in addition to the build and unit checks above. Use a lent
simulator's identifier as `SIMULATOR_UDID`:

```sh
xcodebuild test -project unipad.xcodeproj -scheme unipad -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -only-testing:unipadUITests/PlayInputEdgeUITests -parallel-testing-enabled NO \
  -collect-test-diagnostics never
```

These checks generate their own packs without a shared library setup. On iPhone, exclude
`unipadUITests/PlayInputEdgeUITests/testPointerClicksDragsAndChangesChain`
with `-skip-testing:`; run it on iPad, where pointer interaction is supported.
The suite generates its own looping packs and compares held and released pad
pixels through rotation, pointer input and both `squareButton` settings. Rotation
must cancel the held pad before the finger is lifted. Each scheduled step records both
start and completion using a monotonic clock. Rotation and captures must complete before
gesture invocation plus its requested duration minus 0.25 seconds, and before the
command returns. A late observation fails instead of establishing held-input coverage.
The result bundle keeps the timing records and the actual before/after rotation
captures taken during the hold. `python3 -m unittest discover -s ci -v` also checks
that the shared timing decision rejects a capture completed after release while the
gesture command is still waiting to return. The whole UI target also
includes these checks, but its other suites need their own fixture setup.
`MultiTouchPlayTests.testScreenTurningUnderHeldFingersReleasesThemAndStartsNothing`
and `testPadsMovingUnderAStillFingerReleaseItAndStartNothing` separately check
sound requests and feedback through the pad view's input handlers.

A second gesture during a held press is refused by XCUITest, so pointer/touch
mixing and a margin held while tapping a chain remain unverified on screen.
Resizing an iPad window during a held press is also unverified. Direct handler
tests do not establish those screen paths or audible sound quality.

## App Store destination check

The separate **App Store link** workflow checks the update URL from
`MainView.swift` daily, on demand, and on pull requests changing the URL or its
checker. It is not a required check. Run it locally from the repository root:

```bash
python3 ci/app_store_link.py --out app-store-link.json
python3 -m unittest discover -s ci -v
```

Exit codes are `0` for a verified UniPad destination, `1` for an invalid link,
and `2` for unavailable network or Apple service (a workflow warning).
The JSON records the original and final URLs, HTTP status, Apple lookup app ID
and name, verdict, and UTC check time. Download the latest
`app-store-link-results` artifact for release checks; it is kept for 90 days.
Offline unit tests run in the existing iOS checks. Live unit tests run only with
`UNIPAD_LIVE_STORE_CHECK=1`.

This verdict concerns the web URL. Simulator opening failures do not indicate
an invalid link: simulators lack the App Store app and may open Safari instead.
`--simulator <udid>` records `simctl openurl` diagnostics separately without
changing the verdict. `--source <file>` and `--expected-id <number>` allow
checking a different source or expected app ID.

## Notification simulator check

Acquire an iPhone simulator through your device harness, read its lease
generation, then run the check through the harness's native entry from the
repository root:

```bash
python3 "$HARNESS/devices.py" lease <udid>
python3 "$HARNESS/devices.py" native <udid> --generation <generation> -- \
  ci/notification_roundtrip.py --simulator <udid> \
  --derived-data <scratch>/dd --output <scratch>/notifications
```

Do not run `ci/notification_roundtrip.py` directly. The native entry first
confirms that the simulator's notification service answers, before the test app
is built. A direct run leaves out that confirmation, so a simulator that is not
ready looks like an app failure: a slow notification-settings callback can make
the app skip its permission prompt.

Exit codes:

- `0`: the check passed.
- `75`: the app test never started, because the notification service did not
  answer within 10 seconds or that readiness check could not finish. A slow
  service keeps the readiness check retrying for about 5 minutes before this
  exit, so let the command run. The `DEVICE-NOT-READY notification service:` line
  gives the reason. Run the same command again on the same lease; do not restart
  the simulator.
- `1`: the app test or its build failed, or the harness refused the run, or a
  cleanup failed, and the output says why. Find the cause in the output and saved
  evidence; never rerun a failed app test to get a pass. What a cleanup failure
  leaves depends on which cleanup failed:
  - The harness could not finish its cleanup (a `DEVICE-CLEANUP-UNVERIFIED <udid>`
    line): the lease can no longer be used, even if the printed report also shows
    a script cleanup failure.
  - The script could not remove its test apps (`cleanup_error` in the printed
    report, with no such line): the lease stays usable. `"test_app_removed": false`
    appears only when `simctl uninstall` itself failed; a `simctl` timeout leaves
    the field out and ends the cleanup at that app, so a later app is not tried.
    The harness removes no app data, and either app left behind makes the next run
    stop with `already installed; refusing to replace its data`, so remove
    whichever remains before returning the simulator:

    ```bash
    xcrun simctl uninstall <udid> io.unipad.tests.notifications.unipad
    xcrun simctl uninstall <udid> io.unipad.tests.notifications.unipadUITests.xctrunner
    ```

The output directory must be new. The command builds and installs a separate
Debug test app with fake Firebase configuration, then removes it on exit.
It downloads a local fixture, accepts the fresh notification permission prompt,
requires the prompt to disappear, and opens synthetic notifications from
Notification Center's Open swipe action both while the app is in the background
and after termination.
Screenshots and assertions require the app to return to home with the launch
splash gone and home taking touches: the pack list after the background return,
and the test app's own empty library after the cold launch, which the system
starts without the test's library argument. Runtime logs must show a new
local-only process with no local-only launch argument. `--timeout` (default 300
seconds) bounds the UI test. Commands, exit codes, runtime logs and `UI.xcresult`
are saved in the output directory. Return the simulator through your harness
when the check has finished; after exit `75`, first run it again on the same
lease, and after a script cleanup failure, first remove the apps left behind.
This checks simulator notification handling, not real APNs or Firebase delivery.
The UI test skips when `xcodebuild` runs it directly, because only the script
sets up what it needs.

Debug and builds compiled with `UNIPAD_RELEASE_TESTS` use local Firebase stubs
unless told otherwise, so a fresh install launched without arguments sends no
analytics, crash reports, push registrations or Remote Config requests to
production. The stubs do not cover the store: it still reads the production
catalog and downloads packs from production, unless a release check launches
with its own fixtures. Launching once with `-UniPadFirebaseLocalOnly YES` or
`NO` saves that choice for subsequent launches from notifications or the Home
Screen; `NO` is what a check of real Firebase delivery needs, and running such a
build from Xcode to try push, analytics or Crashlytics needs it too. Uninstalling
the app resets the choice to local. Normal Release/store builds ignore both the
saved choice and launch arguments and always use Firebase. Unit test hosts always
use local stubs.

## Connecting a Launchpad

For an automated simulator check, lend an iPhone simulator through your device
harness and run:

```bash
python3 ci/virtual_launchpad_roundtrip.py --simulator <udid> \
  --derived-data <scratch>/dd --output <scratch>/roundtrip
```

The output folder must be new. The command closes the normal app before sending
test notes, installs a separate Debug test app,
checks the connected MK2 label, sends notes 81 and 82 after the play screen is
ready, and requires each note's receipt and nonzero LED reply. It runs MIDI-first
and screen-first sessions and checks one local `play_first_input` event per
session. Firebase uses local stubs; their `AnalyticsLocal` marker is required.
Logs, command/PID records, shared pack/preference snapshots, screenshots in the
test result bundles, and `result.json` remain in the output folder. A failed
check exits nonzero. `--without-device` is a negative control and must fail the
connection wait. Each wait and the overall run are bounded (20 minutes by
default); cleanup runs on success, failure, and interruption. Return the lent
device through your harness when finished. This opt-in check does not verify
physical USB, hardware latency, or models other than MK2.

1. Connect your Launchpad to your device using a USB adapter or USB-C cable.
2. Open UniPad. The app scans and connects to supported hardware automatically.
3. If you want to change drivers manually, you can pick one from the in-app MIDI menu.

## Project Layout

- `unipad/App`: App entry point and navigation routing
- `unipad/Services/MIDI`: CoreMIDI communication, device drivers and SysEx handling
- `unipad/Services/Audio`: Sound playback engine and audio pool
- `unipad/Services/LED`: LED frame runner and light mapping
- `unipad/Services/Theme`: Theme loader and zip extraction. The app's
  "Create your own theme" button opens the public theme guide on unipad.io
  (Korean and English). If you change which files a theme ZIP may contain or
  how the app reads them, update that guide in the same week:
  `content/docs/en/theme.mdx` and `content/docs/ko/theme.mdx` in
  [kimjisub/unipad.io](https://github.com/kimjisub/unipad.io).
- `unipad/Database`: SwiftData models for saved unipacks
- `unipad/Views`: UI screens (grid player, store, settings, theme picker, midi picker)

## License

This project is licensed under the [GNU Lesser General Public License v2.1](LICENSE).

## Credits

- Original UniPad app and concept by [Kim Ji-Sub](https://github.com/kimjisub).
- Thanks to the UniPack creators and custom firmware developers.

## App Store update checks

The existing home-screen update link uses Apple's public [lookup API](https://performance-partners.apple.com/search-api)
for app `6760479102`. It reads the account's actual [StoreKit storefront](https://developer.apple.com/documentation/storekit/storefront),
converts its ISO alpha-3 country code to alpha-2, and never substitutes the device's
language, region, or another country's store. Missing or unrecognized countries
leave the link hidden. A prompt already on screen stays while StoreKit reads the
storefront again, and is hidden as soon as the storefront reads as another country or
cannot be read, or the installation is not verified; at launch nothing is shown until the
storefront has been read. Storefront changes cancel outstanding work, remove the
saved result, and reject responses from the old country. A storefront or installation that
cannot be read for a moment keeps the saved result, which is only used again for the same
country and a verified installation.

Only a verified production [AppTransaction](https://developer.apple.com/documentation/storekit/apptransaction/shared)
with the running bundle identifier enables checks. Debug builds, TestFlight,
Xcode installations, unavailable/unverified transactions, and nonnumeric version
strings do not enable them. No management credentials or new analytics are used.
The old remote `ios_version` list is no longer read; other remote settings and the
server-side list for older apps are unaffected.

A response must contain exactly one software app with the expected app ID and
running bundle ID, an App Store destination in the requested country, a numeric
version and minimum OS, and a `supportedDevices` list. A newer version is offered only
when its minimum OS is no newer than this device and the list has an entry for its device
family; otherwise the response means there is nothing to offer and is kept for a day like
any other successful lookup. Numeric components compare
without integer overflow (`4.2.9 < 4.2.10`, `4.3 == 4.3.0`). The lookup cannot prove
installation eligibility: exact hardware capabilities, account restrictions,
phased availability, and the final installation decision remain with the App Store.
No prompt is created from an invalid or failed response.

Successful validated results are retained for **24 hours**. Failed public lookups wait
**1 hour** before retrying; neither interval restarts on each home appearance.
These intervals and failures persist across launches, scoped to the country,
installed version, bundle ID, OS, and device family. Expired results are hidden
before revalidation; errors never restore an old prompt or mean “up to date.”
Cancelled requests save no result or retry entry.
Concurrent callers share one task, including StoreKit reads. Requests use an
uncached ephemeral session with **10-second request and resource timeouts**.
Apple documents approximately 20 calls/minute, subject to change; the intervals
reduce requests without assuming that number is a guaranteed quota. Work is
asynchronous and does not hold navigation, import, or playback.

`AppStoreUpdateTests` and `AppStoreLookupTests` inject the clock, country,
installation eligibility, storage, and transport. `AppStoreUpdateUITests` uses
`-UniPadAppStoreResponse available|current|failure|delay`, together with
`-UniPadFirebaseLocalOnly YES -UniPadReleaseTest <UUID>`, to exercise the actual
home/play screens with isolated offline packs. These overrides compile only in
Debug or `UNIPAD_RELEASE_TESTS` builds and are absent from store builds. Injected
responses do not verify an actual store installation or TestFlight receipt.

## Store download completion accounting

Store saves request an opaque receipt independently of the archive transfer and
report it only after the pack is published in the library. Failed downloads,
invalid archives, failed saves and external imports never report completion.
The displayed download count still comes from the next catalog refresh.
Pending completions survive restart for the earlier of the server's expiry and
seven days after saving, with at most 1,000 records and three attempts per rolling
24 hours, at least one minute apart. Retries run only while the app is active.

Production requests require a verified production `AppTransaction` for the running
bundle. Debug, simulator and explicit release-check builds cannot use production
accounting. To connect such a build to the local demo Firebase emulators, pass
`-UniPadDownloadAccountingEmulator YES`. The endpoint is fixed to
`http://127.0.0.1:5051/demo-unipad/us-central1/`; there is no production fallback.
Any HTTP permission needed by the local test installation belongs in that test
installation's configuration, never the store app's transport policy.

The offline checks run with `python3 -m unittest discover -s ci -p 'test_*accounting.py'`
and `python3 -m unittest discover -s ci -p test_store_save_notification.py`.
The latter can reproduce the missing notification on an older revision using
`UNIPAD_STORE_DELEGATE_REVISION=<commit>`.
For a real server integration check, compile the app's two accounting source files
and `ci/download_accounting_emulator.swift` with `swiftc -parse-as-library -D DEBUG`,
then run the executable with a scratch directory under
`firebase emulators:exec --project demo-unipad`. It requires the functions emulator
on port 5051, the database emulator on 9051 and demo database rules that allow the
emulator owner to seed test data. It refuses other project or database hosts.
Use a short temporary directory on macOS if the functions emulator's Unix socket
path exceeds the platform limit.

`StoreDownloadAccountingUITests` checks the installed app against those local
emulators. Set `TEST_RUNNER_UNIPAD_DOWNLOAD_ACCOUNTING_EMULATOR=1` and select that
suite explicitly. It resets only the `demo-unipad` store and accounting fixtures,
then checks separate saves, interrupted transfers, failed transfers and disabled
accounting. It enables CFNetwork diagnostics for the test app. The ordinary UI
runner leaves this suite out because it does not start the emulators.
