# UniPad iOS

<a href="https://apps.apple.com/us/app/unipad/id6760479102">
  <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83" alt="Download on the App Store" height="50">
</a>

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

Every pull request runs one **iOS checks / Build and unit tests** job on a
GitHub-hosted macOS 15 runner with Xcode 26.3. It builds Release for iOS
Simulator without signing and runs the `unipadTests` target in Debug on an
available iPhone simulator. UI tests are excluded. Dependencies use the
committed `Package.resolved` versions.
After the Release build it checks that the app's open source notices list
exactly the Swift packages that build compiled (see below).
The same checks also run after changes are merged into `main`.

The job needs no repository secrets or signing credentials. It replaces the
Firebase plist only in its disposable checkout with clearly fake values from
`ci/firebase_fixture.py`; the existing unit-test runtime uses local Firebase
stubs. App configuration, version, and behavior in normal builds are unchanged.
Build logs and the test result bundle are available in the run's
`ios-check-results` artifact for seven days. This workflow does not upload to
a store or change required checks.

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
  checks need Xcode 27 and iOS 27.
- The script leaves out, by name, the checks it cannot set up, and lists why in
  `ci/ui-tests.sh`: the virtual MIDI round trip (`ci/virtual_launchpad_roundtrip.py`),
  the notification permission round trip (`ci/notification_roundtrip.py`),
  the real-pack LED capture (`UNIPAD_LED_TIMING_VISUAL_PACK`), the real store
  download, and iPad pointer input. Run those separately when a change touches them.
- A full run takes about 80–90 minutes. To split it, pass test classes; the
  parts together must name every class:

  ```bash
  ci/ui-tests.sh <simulator-udid> -only-testing:unipadUITests/PackWarningUITests -only-testing:unipadUITests/PlayChainLayoutTests
  ```

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
built, a version differs from `Package.resolved` or `Vendor/XiphVorbis/vendor.sh`, or a
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

Acquire an iPhone simulator through your device harness, then run:

```bash
python3 ci/notification_roundtrip.py --simulator <udid> \
  --derived-data <scratch>/dd --output <scratch>/notifications
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
immediately afterward.
This checks simulator notification handling, not real APNs or Firebase delivery.
The UI test skips unless invoked through this command.

In Debug and builds compiled with `UNIPAD_RELEASE_TESTS`, launching once with
`-UniPadFirebaseLocalOnly YES` saves the choice for subsequent launches from
notifications or the Home Screen. `-UniPadFirebaseLocalOnly NO` clears it;
uninstalling the app also resets it. Normal Release/store builds ignore both
the saved choice and launch arguments. Unit test hosts always use local stubs.

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
- `unipad/Services/Theme`: Theme loader and zip extraction
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
