# Simulator release feature checks

Run from an isolated checkout after loading the UniPad Paperclip environment:

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/run-release-features.py --os 26.3
```

The command lends a simulator through the harness, runs `ReleaseFeatures` three times in
**Release** configuration, rejects failures, skipped tests and zero-test runs, and returns
the device in `finally`. It records commands, exit codes, test summaries and result bundles
in `$PAPERCLIP_RUN_SCRATCH_DIR/release-features`. Upload the evidence before the run ends.
Do not use `booted` as an Xcode destination. `26.3` is the runtime's harness name; its installed
OS version is 26.3.1. Other supported harness runtime names may be supplied with `--os`.
Use `--derived-data <path>` to reuse a simulator build cache; its exact path is recorded
in every command and the checks still rebuild and execute each iteration.

Equivalent single-run command (substitute the ID printed by `devices.py up-ios`):

```sh
xcodebuild test -project unipad.xcodeproj -scheme unipad -testPlan ReleaseFeatures \
  -configuration Release -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -derivedDataPath "$PAPERCLIP_RUN_SCRATCH_DIR/release-build" \
  -parallel-testing-enabled NO -enableCodeCoverage NO -collect-test-diagnostics never \
  -resultBundlePath "$PAPERCLIP_RUN_SCRATCH_DIR/release-run.xcresult" \
  UNIPAD_TEST_CONDITIONS=UNIPAD_RELEASE_TESTS ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=NO
```

`AllTests` remains the default plan. `ReleaseFeatures` is an explicit selection of feature
checks, not an exclusion list for failing tests. The two plans retain the same test targets.
The plan uses version 2 selections: `suites` for Swift Testing, `xctestClasses` and
`xctestMethods` for XCTest. Legacy string selections only ran XCTest checks in a recorded
probe. The runner checks that every selected suite/method appears in the result bundle;
zero-test and partially executed selections are failures even if Xcode exits successfully.

No repository CI workflow exists at the base commit `e98b6fb`; adding CI belongs to JIS-181.
Before a PR, also run the ordinary simulator Release build without the test condition and
all unit tests with `-testPlan AllTests -only-testing:unipadTests`. There is no SwiftLint
configuration in this repository. Existing compiler warnings must be compared with the base;
new warnings must be fixed.

## Isolation and production behavior

`ReleaseTestSupport` and test-only accessibility values compile in Debug or when explicitly
enabled with `UNIPAD_TEST_CONDITIONS=UNIPAD_RELEASE_TESTS`. They do not compile into a normal
Release/archive build. The additional setting is appended in our project's build settings;
it does not overwrite Swift package conditions such as `SWIFT_PACKAGE`.

A UUID launch argument gives each UI test its own `Documents/ReleaseTests/<UUID>/UniPack`
library and SwiftData history store. Relaunching with that UUID keeps its history. Existing
simulator libraries are not deleted. Silent WAV files, LED scripts and autoplay data are
generated locally. The background test gives its first pad 10,000 finite repeats of
a silent 10 ms buffer and asserts one active voice before Home and a new sound request
after foregrounding. The share/download ZIP is generated with the production ZIP writer.

The store uses a fake `FirestoreServiceProtocol`; share metadata and downloads use
`URLProtocol`. Unexpected requests fail instead of reaching live servers. Firebase analytics,
messaging, remote configuration and crash collection use the existing local-only services.
No Firebase configuration or signing secret is added.

`MidiManager.shared` still creates a manager with no injected transport and follows the same
CoreMIDI calls, driver registry, connection notifications and send queue as before. Tests inject
a `MidiTransport` at the device boundary, then use the production MK2 driver and manager
listener adapters. This checks discovery, connection, two held notes, outgoing LED bytes and
disconnect; it does not claim to test Apple's CoreMIDI port implementation.

## Coverage map

This table describes the implemented checks. Actual pass counts and outstanding checks belong
in the issue's verification record; do not infer that a check passed from its presence here.

| Feature | Status | Existing checks reused | Gap covered | Remaining limitation |
| --- | --- | --- | --- | --- |
| Start, empty/populated list, settings | Automatic | `SettingsBackNavigationTests` | `ReleaseFeatureUITests`: generated empty/populated libraries | None for this simulator flow |
| File/share import, result, open | Automatic | `UniPackImporterOverlapTests`, `ImportResultDialogTests`, downloader tests | File picker plus result/play; share confirmation, download, success and play | Share URL is delivered to the production router by the test host; OS-level URL association needs a separate check |
| Sound request, keyLed, chain, simultaneous input | Partial | LED/parser tests, `PlaybackStopTests` | Two held pads assert sound count and LED code; actual chain button selection | Real sound, touch latency and two physical fingers need device checks |
| Autoplay, pause, stop, practice | Automatic | `PlaybackStopUITests`, `PlaybackStopTests` | Screen transport states and model progress frozen on pause, resumed/stopped state | Hearing playback is outside simulator assertions |
| MIDI discovery/input/output | Partial | Existing driver tests | Fake device boundary with production manager and MK2 driver | CoreMIDI virtual source/destination creation returned `kMIDINotPermitted` (-10844) on iOS 27; physical USB and CoreMIDI integration need device checks |
| Store/download, delete/history/bookmark | Automatic | `StoreDownloadTests`, `PackDeletionTests` | Offline store/download; delete and reinstall the same pack, assert bookmark and play count cleared | Real store availability is monitored separately |
| Language, skin, rotation, safe area | Partial | `AppLanguageTests`, `PlayThemeLayoutTests`, `StoreListEndTests` | Reuse with self-prepared packs and offline store | Settings' language row has no change action in the current app; no in-app language switch is claimed. Older screens require their own independent safe-area reference |
| Background/lock return | Partial | Audio interruption unit tests | Active finite-repeat voice, Home button, foreground return, new sound request and exit | XCTest cannot press the simulator lock button with its public device API; real lock/unlock is a physical-device check |

## Manual release checks

- Connect a supported physical Launchpad, press two pads together, change chains and verify
  the physical LEDs and correct sound; unplug/reconnect without leaving playback.
- With real audio playing, lock/unlock a physical iPhone, background/foreground and verify
  input, audio recovery, continued responsiveness and no crash. Read the candidate's crash data.
- Change the app language through iOS Settings and reopen it. The app currently does not offer
  an in-app language picker; adding one would require separate product authorization.
- Physical sound, USB wiring and physical lock-button operation are unavailable to these
  simulator assertions. Their partial status is an explicit release check, not a skipped test.
- Run the same plan on other supported OS/device sizes when available. A missing independent
  safe-area reference fails the layout check rather than silently skipping it.
