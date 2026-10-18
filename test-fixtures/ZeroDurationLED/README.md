# Zero-duration LED fixture

Original, silent test data. Copy `info`, `keySound` and `keyLed` to a fresh
`Documents/UniPack/ZeroDurationLED` folder in the app installed on the simulator
leased by `devices.py`. Leave existing packs intact.

Run `ZeroDurationLedUITests` with that simulator ID and parallel testing disabled.
The first pad finishes dark; the second, with `d 0`, stays lit. The test presses
both repeatedly and exits to home. The unit tests verify the complete pad and
circular LED output and all three passes of a timed finite animation.

On unfixed code the first pad can lock the screen and allocate a very large
pending LED batch. Bound reproduction externally and terminate only this app
on the leased simulator after capturing the unresponsive state.
