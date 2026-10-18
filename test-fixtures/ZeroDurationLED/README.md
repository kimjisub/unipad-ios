# Zero-duration LED fixture

Original, silent test data. Copy `info`, `keySound` and `keyLed` to a fresh
`Documents/UniPack/ZeroDurationLED` folder in the app installed on your iOS
simulator. Leave existing packs intact.

Run `ZeroDurationLedUITests` with that simulator ID and parallel testing disabled.
The first pad finishes dark; the second, with `d 0`, stays lit. The test presses
both repeatedly and exits to home. The unit tests verify the complete pad and
circular LED output and all three passes of a timed finite animation.

On unfixed code the first pad can lock the screen and allocate a very large
pending LED batch. Debug builds also terminate after a five-second input-lock
wait. Bound reproduction externally and stop the tested app promptly after
capturing the unresponsive state.
