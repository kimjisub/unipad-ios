# iOS playback conformance

The test bundle contains the unchanged shared corpus and its SHA-256. The harness
compares recorded output with the corpus expectations; it does not derive those
expectations from the iOS implementation.

`AutoMapProductTests` runs the five shared mapping operations through the app's mapper,
with each operation's sound lengths supplied in place of reading audio, and reports the
commands read back from the saved file. It says nothing about decoding real sounds.

`RUN-L-006`, `RUN-L-007`, `RUN-A-001`, `RUN-A-002`, `RUN-RP-003`, and `RUN-RP-004`
were marked `unobserved` for iOS until the harness gained the virtual autoplay clock
and the screen-return observation below; the corpus no longer marks them. A case the
corpus does mark `unobserved` for iOS is reported unverified with its reason and not run.

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

`autoplayOff` stays on the play screen and invokes `PlayViewModel.switchPlayMode(.none)`.
Scenarios using it send manual and autoplay inputs through `PlayViewModel.padTouch`,
with separate input identities and the production runner's cancellation callbacks.
`looping` reports coordinates for infinite sounds whose playback IDs are still
active in the real `SoundEngine`; it does not infer liveness from input events.
`RUN-RP-005` checks the two held sounds before autoplay is disabled, the surviving
manual sound afterward, no later autoplay events, and silence after manual release.
A self-check omits the screen's autoplay-off action and requires this case to fail.

`watchStops` observes the real engine's `activePlayIDs` before and after each pad
press or release. Each started ID is associated with its original chain, pad and
file; an ID removed by that action emits `soundStop`, before a replacement's
`sound` event. A release is not itself evidence of a stop. These cases advance no
virtual time, so the existing `playbackCompletionDelivery` seam holds finite
completion callbacks until shutdown. Scheduling and stopping still use the real
audio engine, and failure callbacks are delivered normally. This prevents a slow
simulator from naturally finishing a 10 ms sample between two actions that the
scenario places at the same instant. It observes engine voice state, not captured
audio or a physical speaker.

Chain-selection scenarios now install `PlayViewModel.setupChainObserver` on the
same pack and chain as the sound and LED runners. The `chain` step invokes
`PlayViewModel.selectChain`; a sound's delayed wormhole reaches that same observer.
The harness does not duplicate queue-reset logic. The checks compare both sound
and LED selections after selecting the same chain again, and the sound selection
after returning through a wormhole.

`RUN-S-008`, `RUN-S-009`, `RUN-S-010`, `RUN-S-012`, and `RUN-S-013` must all produce
measured results. Self-checks omit sound release or the screen's chain observer
and require the corresponding cases to fail against their unchanged expectations.
