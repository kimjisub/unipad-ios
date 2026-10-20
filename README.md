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
leave the link hidden. The previous prompt is hidden while StoreKit resolves
the current storefront and installation. Storefront changes cancel outstanding work, remove the
saved result, and reject responses from the old country.

Only a verified production [AppTransaction](https://developer.apple.com/documentation/storekit/apptransaction/shared)
with the running bundle identifier enables checks. Debug builds, TestFlight,
Xcode installations, unavailable/unverified transactions, and nonnumeric version
strings do not enable them. No management credentials or new analytics are used.
The old remote `ios_version` list is no longer read; other remote settings and the
server-side list for older apps are unaffected.

A response must contain exactly one software app with the expected app ID and
running bundle ID, an App Store destination in the requested country, a numeric
version, a minimum OS no newer than this device,
and a `supportedDevices` entry for its device family. Numeric components compare
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
