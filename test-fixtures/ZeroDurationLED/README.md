# Zero-duration LED fixture

Original, silent test data. Copy `info`, `keySound` and `keyLed` to a fresh
`Documents/UniPack/ZeroDurationLED` folder in the app installed on your iOS
simulator. Leave existing packs intact.

Run `ZeroDurationLedUITests` with that simulator ID and parallel testing disabled.
The first pad finishes dark; the second, with `d 0`, stays lit. The third waits
10 ms, turns off, then moves logical time back by 20 ms. The test presses all
three repeatedly and exits to home. It records tap duration and screenshots;
it asserts successful navigation, while unit tests assert final pad and circular
LED output, completion of huge non-advancing loops, and all three timed passes.

On unfixed code the first pad can lock the screen and allocate a very large
pending LED batch. Debug builds also terminate after a five-second input-lock
wait. Bound reproduction externally and stop the tested app promptly after
capturing the unresponsive state.
