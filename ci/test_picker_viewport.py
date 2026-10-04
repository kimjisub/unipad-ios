"""Run the actual picker viewport check while the folder's tabs arrive late."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PickerViewportTests(unittest.TestCase):
    def test_folder_navigation_waits_for_the_same_visible_controls(self):
        source = (Path(__file__).resolve().parents[1] / "unipadUITests/UITestSupport.swift").read_text()
        start = source.index("        let search = app.searchFields.firstMatch")
        end = source.index("        func visible()", start)
        viewport = source[start:end]
        start = source.index("    static func waitForSettledFrame(")
        end = source.index("    private static func attachPickerDiagnostics", start)
        wait = source[start:end]
        program = r"""
import Foundation
import XCTest
var assertionFailures = 0
func XCTAssertTrue(_ expression: Bool, _ message: String = "") {
    if !expression { assertionFailures += 1; print(message) }
}
final class Element {
    let frame: CGRect
    let arrivesAt: Date?
    var exists: Bool { arrivesAt.map { Date() >= $0 } ?? false }
    init(frame: CGRect, arrivesAt: Date?) { self.frame = frame; self.arrivesAt = arrivesAt }
    func waitForExistence(timeout: TimeInterval) -> Bool {
        guard let arrivesAt else { return false }
        while Date() < arrivesAt { Thread.sleep(forTimeInterval: 0.01) }
        return true
    }
}
struct Query { let firstMatch: Element }
final class App {
    let searchFields: Query
    let tabBars: Query
    let windows = Query(firstMatch: Element(frame: CGRect(x: 0, y: 0, width: 874, height: 402), arrivesAt: Date()))
    init(lateTabs: Bool, missingTabs: Bool = false) {
        searchFields = Query(firstMatch: Element(frame: CGRect(x: 78, y: 78, width: 718, height: 44), arrivesAt: Date()))
        tabBars = Query(firstMatch: Element(frame: CGRect(x: 280, y: 338, width: 314, height: 44),
            arrivesAt: missingTabs ? nil : Date().addingTimeInterval(lateTabs ? 0.5 : 0)))
    }
}
struct Support {
    static func attachPickerDiagnostics(in app: App, details: String) {}
""" + wait + "\n    static func viewport(in app: App) -> CGRect {\n" + viewport + r"""
        return viewport
    }
}
var passed = true
for late in [false, true] {
    assertionFailures = 0
    let app = App(lateTabs: late)
    let rect = Support.viewport(in: app)
    let ok = assertionFailures == 0 && app.tabBars.firstMatch.exists &&
        rect == CGRect(x: 0, y: 126, width: 874, height: 208)
    print(late ? "late tabs" : "immediate tabs", ok ? "passed" : "failed")
    passed = passed && ok
}
assertionFailures = 0
_ = Support.viewport(in: App(lateTabs: false, missingTabs: true))
print("missing tabs rejected:", assertionFailures > 0)
passed = passed && assertionFailures > 0
exit(passed ? 0 : 1)
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
            result = subprocess.run([str(path / "probe")], capture_output=True, text=True, timeout=120)
            print(result.stdout, end="")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
