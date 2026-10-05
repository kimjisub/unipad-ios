# Play usage fixture

Original test data: three silent pad sounds and an 800 ms automatic sequence. No user pack or
third-party audio is included. This directory stays outside Xcode's synchronized test groups so
its `info`, `keySound`, `autoPlay` and `a.wav` names cannot collide with other fixtures.

For `PlayUsageRecordUITests`, install the built app on the simulator leased by `devices.py`, then
copy this directory to that app's `Documents/unipack/JIS20FirstInputFixture`. Do not replace an existing
folder. Remove only this copied fixture after the test. The UI test fails if it is missing.

Run `xcodebuild test` with `-only-testing:unipadUITests/PlayUsageRecordUITests`, the leased device
ID and `-parallel-testing-enabled NO`. `UITestSupport` supplies `-UniPadFirebaseLocalOnly YES`.
Capture the same device's `log stream --level info --predicate 'category == "AnalyticsLocal"'`
while the tests run. UI screenshots and steps prove the screen interactions; the local log proves
which events the app handed to its sink. Neither proves Firebase receipt or release inclusion.

Expected records after `pack_load`:

| Scenario | Records |
| --- | --- |
| U1 menu only, U2 step selection, U3 guide selection | None |
| U4 screen pads, U7 human pad in step practice | `play_start` pad, `play_first_input` pad, `play_end` |
| U5 automatic sequence, U8 step to automatic sequence | `play_start` autoplay, `play_end` |
| U6 human pad then autoplay | `play_start` pad, `play_first_input` pad, `play_end` |
| U9 autoplay then human pads | `play_start` autoplay, `play_first_input` pad, `play_end` |

The unit suite also drives decoded MIDI input, both practice modes, input before readiness,
invalid coordinates, repeat callbacks and repeated cleanup. Each scenario uses its own analytics
sink under a single serialized suite. The pack-loading tests are nested in that same
`PlayUsageRecordTests` suite because becoming ready also replaces `MidiManager.shared.controller`.
Swift Testing's recursive `.serialized` trait prevents the two groups from overlapping; giving
each group its own serialized trait would still allow them to overlap. A regression test checks
the loading test's runtime parent, so moving it back to a separate suite fails.

Select `-only-testing:unipadTests/PlayUsageRecordTests` to run both groups, or
`-only-testing:unipadTests/PlayUsageRecordTests/PlayViewModelLoadTests` for only loading.
`PlaybackStopTests` uses XCTest, which finishes before Swift Testing starts in this test target.
Use `-parallel-testing-enabled NO` to keep Xcode from cloning the harness-leased simulator.
Observation failures are regular test failures.
