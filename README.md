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
The same checks also run after changes are merged into `main`.

The job needs no repository secrets or signing credentials. It replaces the
Firebase plist only in its disposable checkout with clearly fake values from
`ci/firebase_fixture.py`; the existing unit-test runtime uses local Firebase
stubs. App configuration, version, and behavior in normal builds are unchanged.
Build logs and the test result bundle are available in the run's
`ios-check-results` artifact for seven days. This workflow does not upload to
a store or change required checks.

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

## Connecting a Launchpad

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
