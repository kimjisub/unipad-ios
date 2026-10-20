"""Run the UI helper's timing decisions without a simulator or synthesized input."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class HeldInputTimingTests(unittest.TestCase):
    def test_completion_must_precede_the_conservative_release_deadline(self):
        source = Path(__file__).resolve().parents[1] / "unipadUITests/HeldInputTiming.swift"
        probe = r"""
import Foundation

let cases: [(String, Double, Double, Double, Double, Bool)] = [
    ("completed during hold", 1, 2, 5, 7, true),
    ("capture finished after release before command returned", 1, 5.1, 5, 7, false),
    ("capture crossed conservative deadline", 1, 4.8, 5, 7, false),
    ("capture ended at conservative deadline", 1, 4.75, 5, 7, false),
    ("capture finished after early command return", 1, 2, 5, 1.5, false),
    ("step began after release", 5.1, 5.2, 5, 7, false),
    ("completion precedes start", 2, 1, 5, 7, false),
    ("step began before invocation", -1, 1, 5, 7, false),
]
var failures = 0
for (name, started, completed, duration, returned, expected) in cases {
    let actual = HeldInputTiming(started: started, completed: completed)
        .finishedWhileHeld(duration: duration, commandReturned: returned)
    print("\(actual == expected ? "PASS" : "FAIL"): \(name)")
    if actual != expected { failures += 1 }
}
exit(failures == 0 ? 0 : 1)
"""
        with tempfile.TemporaryDirectory(dir=os.environ.get("PAPERCLIP_RUN_SCRATCH_DIR")) as scratch:
            scratch = Path(scratch)
            (scratch / "main.swift").write_text(probe)
            executable = scratch / "timing-check"
            subprocess.run(["swiftc", str(source), str(scratch / "main.swift"), "-o", str(executable)],
                           check=True, capture_output=True, text=True, timeout=120)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout, end="")


if __name__ == "__main__":
    unittest.main()
