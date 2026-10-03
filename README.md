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

Every pull request runs **iOS checks / Build and unit tests** on a
GitHub-hosted macOS 15 runner with Xcode 26.3. It builds Release for iOS
Simulator without signing and runs the `unipadTests` target in Debug on an
available iPhone simulator. Dependencies use the
committed `Package.resolved` versions.

The staged **iOS checks / UI tests** job runs the entire `unipadUITests` target
in Debug on iPhone 17 Pro with iOS 26.3, with parallel execution disabled.
That device has independently measured safe-area references in the layout tests. No class or
test is excluded: `DesignScreenshots` asserts that navigation reaches each
screen, so it remains part of regression coverage. `ci/check_ui_results.py`
rejects failed, skipped, empty, and incomplete results, including tests that
skip because their input packs were not prepared. Logs, screenshots and the
result bundle are saved in `ios-ui-check-results` for seven days.

The UI runner sets `TEST_RUNNER_UNIPAD_RELEASE_SUITE=1`. Each test launch then
uses a UUID-scoped library and history store. Search and deletion checks generate
their own packs; import checks generate a silent archive in Documents and select
it through the system picker. Counts and recent packs are prepared through UI
playback. A deletion-error check protects the generated pack and unlocks it in
teardown. Missing setup fails instead of skipping a check. The fixture code is
compiled out of ordinary Release/archive builds.

For a local run, use the same `xcodebuild` command in the workflow and export
`TEST_RUNNER_UNIPAD_RELEASE_SUITE=1` first. Use iOS 26.3: on the local iOS 27 runtime,
XCTest waits 300 seconds for crash-reporter synchronization after each UI test,
even when its screen assertions pass. This work does not add SwiftLint; warning
policy and any new lint tool are a separate technical-owner decision.

Both jobs need no repository secrets or signing credentials. They replace the
Firebase plist only in its disposable checkout with clearly fake values from
`ci/firebase_fixture.py`; the existing unit-test runtime uses local Firebase
stubs. App configuration, version, and behavior in normal builds are unchanged.
Build logs and the test result bundle are available in the run's
`ios-check-results` artifact for seven days. This workflow does not upload to
a store or change required checks.

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
