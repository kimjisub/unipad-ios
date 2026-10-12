# iOS playback conformance

The test bundle contains the unchanged shared corpus and its SHA-256. The harness
compares recorded output with the corpus expectations; it does not derive those
expectations from the iOS implementation.

The corpus's historical iOS `unobserved` annotations for `RUN-L-006`, `RUN-L-007`,
`RUN-A-001`, `RUN-A-002`, `RUN-RP-003`, and `RUN-RP-004` predate the harness's
virtual autoplay clock and screen-return observation. Only those six annotations
are superseded by actual execution here. Other unobserved cases remain unverified.
The shared report aggregator must also recognize this new evidence before its
combined table can replace those historical annotations.

Autoplay uses the production `AutoPlayRunner`, with injected time reads and
suspension. Each virtual advance waits until the task completes its tick and
suspends again. The LED runner and autoplay share the same elapsed time, with
four-millisecond LED ticks. Production defaults still use `CACurrentMediaTime`
and `Task.sleep`.

A scenario's `stop` cancels playback and invokes `MainViewModel.setupMidiController`
and its real adapter's attach callback, the same controller stage used when the
main route returns. A MIDI driver spy observes `sendClearLed` and reports which
previously lit playback coordinates it clears. Driver restoration is excluded
from this observation so omitting the main-screen stage cannot accidentally pass.
Home-screen watermark and selection lights are outside the playback trace.
This checks the app's hardware-clear request, not delivery to a physical Launchpad
or the disappearance of rendered pads. UI tests cover player exit separately.

The regression tests require the six cases to be measured and check that omitting
the main-screen attach or autoplay cancellation changes the result to a failure.
No new known differences are pinned to make these checks pass.
