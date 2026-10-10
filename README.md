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
in Debug on iPhone 17 Pro with iOS 27, using the GitHub-hosted `xcode-27` preview
image and Xcode 27. Parallel execution is disabled.
That device has independently measured safe-area references in the layout tests. No class or
test is excluded: `DesignScreenshots` asserts that navigation reaches each
screen, so it remains part of regression coverage. `ci/check_ui_results.py`
rejects failed, skipped, empty, and incomplete results, including tests that
skip because their input packs were not prepared. Logs, screenshots and the
result bundle are saved in `ios-ui-check-results` for seven days.

The UI runner sets `TEST_RUNNER_UNIPAD_RELEASE_SUITE=1`. Each test launch then
uses a UUID-scoped library and history store. Search, deletion and play-usage checks generate
their own packs; import checks generate a silent archive in the isolated Documents/00-ReleaseTestImports folder and select
it through the system picker. Counts and recent packs are prepared through UI
playback. A deletion-error check protects the generated pack and unlocks it in
teardown. Loading-layout checks explicitly request the larger silent fixture from main so
the unchanged frame assertions observe both loading and playback without an app delay.
Picker control arrival and frame stabilization have separate bounded waits; a
host test executes the actual Swift wait for late, missing and moving controls.
File-picker checks also start from Recents and scroll inside the unobscured file viewport.
If picker readiness or archive visibility fails, screenshots, the accessibility
hierarchy and the measured bounds are retained for diagnosis.
Missing setup fails instead of skipping a check. The fixture code is
compiled out of ordinary Release/archive builds.

The full UI command runs through `ci/host-keys.sh`. It provides the test runner
with a host responder that presses Escape through the simulator HID interface
using the pinned, checksum-verified AXe release. The same bridge also runs the
English and Korean VoiceOver focus checks, which require Xcode 27 and iOS 27.
No OS-dependent skip is accepted by the result gate. The responder uses the run
scratch directory, exits after the test command, and prints key actions into
the saved UI log as they occur. Each host response records success or failure
and the HID output in the test result bundle; a failed send cannot be accepted
as a completed key press. The app's dismissal and focus assertions still check
that the delivered input had its intended effect.
On Xcode 27, the new HID service can exit while idle with legacy keyboard input
still disabled. Before each request the responder reads this device's input
activation state and wakes its existing service when active, so AXe selects the
working transport. It sends each key once and does not change simulator settings.

For a local run, use the same `ci/host-keys.sh` command in the workflow with a
harness-leased iPhone 17 Pro on iOS 27 and export
`TEST_RUNNER_UNIPAD_RELEASE_SUITE=1` first. The wrapper disables automatic test
diagnostic collection: on the local iOS 27 runtime, crash-reporter synchronization
can otherwise wait 300 seconds after each test. Assertions and result checks
still run; the `.xcresult` bundle and screenshots remain saved. This work does not add SwiftLint; warning
policy and any new lint tool are a separate technical-owner decision.

Both jobs need no repository secrets or signing credentials. They replace the
Firebase plist only in its disposable checkout with clearly fake values from
`ci/firebase_fixture.py`; the existing unit-test runtime uses local Firebase
stubs. App configuration, version, and behavior in normal builds are unchanged.
Build logs and the test result bundle are available in the run's
`ios-check-results` artifact for seven days. This workflow does not upload to
a store or change required checks.

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
