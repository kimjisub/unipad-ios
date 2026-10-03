"""Run the actual Swift picker wait without launching a simulator."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PickerDeadlineTests(unittest.TestCase):
    def test_late_arrival_has_time_to_settle_without_accepting_missing_or_moving_controls(self):
        source = (Path(__file__).resolve().parents[1] / "unipadUITests/UITestSupport.swift").read_text()
        start = source.index("    static func waitForSettledFrame(")
        end = source.index("    private static func attachPickerDiagnostics", start)
        helper = source[start:end]
        program = "import Foundation\nimport XCTest\nstruct Support {\n" + helper + "}\n" + r"""
let target = CGRect(x: 740, y: 28, width: 37, height: 36)
let stable = Support.waitForSettledFrame(timeout: 3,
    waitForArrival: { _ in true }, frame: { target })
let arrivesAt = Date().addingTimeInterval(2.8)
let late = Support.waitForSettledFrame(timeout: 3,
    waitForArrival: { _ in Thread.sleep(until: arrivesAt); return true },
    frame: { Date() >= arrivesAt ? target : nil })
let missing = Support.waitForSettledFrame(timeout: 3,
    waitForArrival: { _ in false }, frame: { nil })
var position = 0
let moving = Support.waitForSettledFrame(timeout: 3,
    waitForArrival: { _ in true }, frame: {
        position += 1
        return CGRect(x: position, y: 28, width: 37, height: 36)
    })
print("Stable control settled:", stable, "late control settled:", late, "missing accepted:", missing, "moving accepted:", moving)
exit(stable && late && !missing && !moving ? 0 : 1)
"""
        developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
        frameworks = str(Path(developer) / "Platforms/MacOSX.platform/Developer/Library/Frameworks")
        scratch = os.environ.get("PAPERCLIP_RUN_SCRATCH_DIR") or os.environ.get("RUNNER_TEMP")
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            path = Path(directory)
            (path / "probe.swift").write_text(program)
            compiled = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-F", frameworks,
                "-Xlinker", "-rpath", "-Xlinker", frameworks,
                str(path / "probe.swift"), "-o", str(path / "probe")],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(path / "probe")], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
