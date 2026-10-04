# Simulator release feature checks

Run from an isolated checkout after loading the UniPad Paperclip environment:

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/run-release-features.py --os 26.3
```

The command lends a simulator through the harness, runs `ReleaseFeatures` three times in
**Release** configuration, rejects failures, skipped tests and zero-test runs, and returns
the device in `finally`. It records commands, exit codes, test summaries and result bundles
in a fresh `$PAPERCLIP_RUN_SCRATCH_DIR/release-features-<UUID>` directory (printed at startup). Upload the evidence before the run ends.
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
  -test-timeouts-enabled YES -default-test-execution-time-allowance 300 \
  -maximum-test-execution-time-allowance 600 \
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
generated locally. The repeat-stop fixture and the background test give their first pad 10,000 finite repeats of
a silent 10 ms buffer and asserts one active voice before Home and before switching to
iOS Settings, with a new sound request after each return. The stop/exit UI test also requires one active voice after four
inputs before leaving each of its three rounds. The share/download ZIP is generated with the production ZIP writer.

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
| Background/lock return | Partial | Audio interruption unit tests and the existing background UI test | Active finite-repeat voice, Home and Settings return, new sound requests; ordinary target Release app, common player controls, retained pad trace, same process ID and no new crash reports | Ordinary app has no active-voice counter; silent fixture and host audio inventory cannot prove actual sound. The installed command paths did not exercise a lock button; physical lock/audio recovery need a device check |

## Compare ordinary Release apps

Use the same entry point for the previous public source and the candidate:

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/run-release-features.py --os 26.3 --target-ref fe2e99c
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/run-release-features.py --os 26.3 --target-ref de32ad0
```

Each command runs three iterations by default. `--iterations 1` is useful for a focused
probe. To prove restart detection, run a negative control; **a nonzero exit is expected**:

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/run-release-features.py --os 26.3 --target-ref de32ad0 --iterations 1 --inject-restart
```

All three test command paths (feature plan, fixture preparation and ordinary target)
set XCTest timeouts: enabled, 300 seconds default and 600 seconds maximum per test.
The runner's separate process limits (360 seconds for the ordinary-target UI invocation,
1800 seconds for other commands) remain recorded; these are not XCTest timeouts.

The exact target commit is archived without any credential configuration. A generated,
invalid Firebase plist replaces that resource. The target is built as ordinary unsigned
Release with an empty `UNIPAD_TEST_CONDITIONS` and `ENABLE_TESTABILITY=NO`; product Swift
sources are unchanged. The test runner is built from this checkout. Its target app path
points to the ordinary Release app, not the instrumented app used to generate the fixture.
The fixture is copied from the existing `ReleaseTestSupport` generator after the original
background test prepares and validates it; there is no second pack generator.

The target receives `XCTestConfigurationFilePath=release-target-local-only`. Both specified
versions check this environment key before configuring Firebase and use local services.
No real Firebase file or signing secret is read from source. The receipt records source and
app hashes, target version/build, launch isolation, commands and process checkpoints.

The target UI branch of the existing background test opens the exact generated pack,
uses the common `line.3.horizontal` menu and the production Trace Log option, presses
pads, activates `com.apple.Preferences`, returns and presses a different sound pad again, then ends on the returned player.
The instrumented suite retains the repeated-pad and player exit checks. It does not rely on `playPadGrid`, absent from 4.1.6. It infers the landscape safe area from the common
menu control in its 56-point trailing strip, and records and validates that geometry.
A point inside both versions' corresponding pad interiors is tapped (their overlap
is checked explicitly): the repeat pad before switching and
the next, one-shot sound pad after return. Retriggering the public version's active repeat
pad can enter its known stop defect (JIS-42, fixed by PR #51); that failure is recorded during
development, and repeat-pad retriggering remains in the instrumented scenario. Retained trace image differences
prove canvas input before and after return. This does not count voices or prove real sound.

Host checkpoints acknowledge the target's process ID before switching, in Settings,
after return and after input. The ordinary app may be running or suspended in the
background; its observed XCTest state is recorded. Missing/restarted processes fail, even if a new app shows
an apparently valid screen. New UniPad crash reports in the host and the lent simulator's
report folders fail the run. Host reports are restricted to the lent device and compared
by content, so touching an old file or another worker crash cannot fail this check. Native `simctl` capture files and accessibility trees accompany each iteration. Native
captures avoid XCTest landscape PNG metadata that some viewers rotate incorrectly.
The negative control terminates the app in Settings, explicitly relaunches with the
local-only environment, and records the PID mismatch on return. A development probe
found automatic activation after termination omitted that environment and rejected the
invalid Firebase key; this is a runner isolation failure, not a production-app crash claim.

### Borrowed-device data

Commands from the same run are serialized by a nonblocking file lock held through
restoration and device return; an overlapping command fails before borrowing a device.
Before any install/test, terminate UniPad and copy its original installed app and **entire**
data container, including Documents, preferences, SwiftData files and journal files. Verify
both copies by relative-path hashes before modifying anything. When no app was installed,
record that state and uninstall the test app afterward. In `finally`, restore the original
app and container, compare their complete before/after hashes, and return the device through
`devices.py down` even if restoration fails. Both termination and interrupt requests use the same cleanup path. Once cleanup starts,
requests are recorded without interrupting restoration, hash verification, device return or
receipt writing; the command then fails to report the requested stop. Isolated, device-free
regressions send the first request just after data deletion and midway through copying,
including repeated requests, and verify complete restored hashes before returning the device.

Original app/data copies live in the checkout's ignored, private (mode 0700)
`.release-feature-recovery/release-features-<UUID>/original` directory, outside run-owned
scratch. A manifest records the lent ID, bundle and original hashes. The runner deletes this
copy only after successful app and complete data hash verification. If restoration fails,
`receipt.json` records `recoveryBackupPath` and `recoveryBackupPreserved`; the copy and
manifest survive run scratch cleanup for a subsequent harness-lent recovery of that exact
device. Do not delete the worktree or this copy until recovery is confirmed, and never
upload, commit or share its private contents. The copy is local recovery material, not a
review artifact. Uncatchable stops (SIGKILL or host failure) cannot run `finally`; the same
persistent copy remains available for recovery. Cleanup errors fail the command and remain in
`receipt.json`; a partial backup never authorizes replacement. Original private backups
are for restoration only: never include them, archived sources or built apps in evidence uploads.

### Lock and audio boundaries

| Check | Tool evidence | Requires a physical iPhone |
| --- | --- | --- |
| Home and Settings return | Instrumented repeat voice and new sound request; target PID, player and pad trace | Actual sound continuity and recovery |
| Simulator lock/unlock | Record the `simctl io <lent-id> press lock` result; unsupported commands are recorded as a limitation | Real lock button, lock-screen behavior and return |
| Audio output | Record host audio inventory; it has no per-app active-voice reading and the fixture is silent | Audible output during switching/locking, correct sound and latency |

In the recorded development run, `simctl io ... press lock` returned 117, AXe was
not installed, and the selected GUI automation executable failed with
`[Errno 2] No such file or directory: 'orca'`. These are tool availability limits,
not a passing lock test. If another GUI tool becomes available, its device target must
match the harness-lent ID and its version-matched guide must be read first.

The local runner regressions require no device:

```sh
. /Users/kimjisub/GitHub/unipad/project/paperclip/env.sh && python3 meta/check-release-features.py
```

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
