"""Exercise first-move diagnostics with the actual Swift test helper, without a device."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class VoiceOverReadingTests(unittest.TestCase):
    def test_first_move_preserves_speech_and_distinguishes_delivery_errors_without_retrying(self):
        root = Path(__file__).resolve().parents[1]
        program = r'''
import Foundation

func require(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}

for speech in ["Connection and light help", "연결·불빛 도움말", ""] {
    var calls = 0
    let actual = try VoiceOverReading.firstSpeech {
        calls += 1
        return speech
    }
    require(actual == speech && calls == 1, "Speech must reach the existing content checks unchanged")
}

let delivery = NSError(domain: "AXVoiceOverAutomationErrorDomain", code: 3,
                       userInfo: [NSLocalizedDescriptionKey: "Failed to send moveForward command"])
var calls = 0
do {
    _ = try VoiceOverReading.firstSpeech { calls += 1; throw delivery }
    require(false, "Delivery failure must remain a failure")
} catch let error as VoiceOverReading.AutomationNotReady {
    require(error.underlying === delivery, "Keep the original error for diagnosis")
    require(error.localizedDescription.contains("VoiceOver automation not ready (test tool)"),
            "Identify the tool failure")
    require(error.localizedDescription.contains("app speech has not been checked"),
            "Do not blame app speech before a command is delivered")
    require(String(describing: error).contains("VoiceOver automation not ready (test tool)"),
            "XCTest's thrown-error text must identify the tool failure too")
} catch {
    require(false, "First-move delivery failure lacks tool diagnostics: \(error)")
}
require(calls == 1, "Never retry a failed movement command")

for other in [NSError(domain: "AXVoiceOverAutomationErrorDomain", code: 4),
              NSError(domain: "OtherErrorDomain", code: 3)] {
    do {
        _ = try VoiceOverReading.firstSpeech { throw other }
        require(false, "Other errors must remain failures")
    } catch {
        require((error as NSError) === other, "Do not reclassify unrelated or missing-speech errors")
    }
}
print("PASS: unchanged speech, diagnosed delivery failure, original errors, one command only")
'''
        scratch = os.environ.get("UNIPAD_TEST_TMPDIR") or os.environ.get("RUNNER_TEMP")
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            folder = Path(directory)
            (folder / "main.swift").write_text(program)
            compiled = subprocess.run(
                ["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors",
                 str(root / "unipadUITests/VoiceOverReading.swift"), str(folder / "main.swift"),
                 "-o", str(folder / "probe")], capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(folder / "probe")], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout, end="")


if __name__ == "__main__":
    unittest.main()
