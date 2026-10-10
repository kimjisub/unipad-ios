"""Exercise the actual picker-row navigation with clipped accessibility frames."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PickerRowTests(unittest.TestCase):
    def test_hittable_but_clipped_rows_are_revealed_before_one_tap(self):
        source = (Path(__file__).resolve().parents[1] / "unipadUITests/UITestSupport.swift").read_text()
        start = source.index("        func tapRow(")
        end = source.index("        let browse =", start)
        row = source[start:end]
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
enum Match { case any }
final class Element {
    var storedFrame: CGRect
    var frameDelay: TimeInterval = 0
    var frameReads = 0
    var frame: CGRect {
        get { frameReads += 1; Thread.sleep(forTimeInterval: frameDelay); return storedFrame }
        set { storedFrame = newValue }
    }
    var exists = true
    let isHittable = true
    var taps = 0
    var accepted = false
    init(_ frame: CGRect) { self.storedFrame = frame }
    func waitForExistence(timeout: TimeInterval) -> Bool {
        if delayedStabilization { frameDelay = 3 }
        return exists
    }
    var delayedStabilization = false
    func tap() {
        taps += 1
        accepted = CGRect(x: 0, y: 24, width: 874, height: 354).contains(frame)
    }
}
struct Query {
    var firstMatch: Element
    func matching(_ predicate: NSPredicate) -> Query { self }
}
final class App {
    let row: Element
    let windows = Query(firstMatch: Element(CGRect(x: 0, y: 0, width: 874, height: 402)))
    var scrolls = 0
    init(_ frame: CGRect) { row = Element(frame) }
    func descendants(matching: Match) -> Query { Query(firstMatch: row) }
    // Reproduce the recorded landscape app gesture: it moves horizontally.
    func swipeUp(velocity: Match) { scrolls += 1; Thread.sleep(forTimeInterval: 0.05) }
    func swipeDown(velocity: Match) { scrolls += 1; Thread.sleep(forTimeInterval: 0.05) }
    func coordinate(withNormalizedOffset offset: CGVector) -> Coordinate {
        Coordinate(app: self, point: CGPoint(x: offset.dx * 874, y: offset.dy * 402))
    }
}
struct Coordinate {
    let app: App
    let point: CGPoint
    func withOffset(_ offset: CGVector) -> Coordinate {
        Coordinate(app: app, point: CGPoint(x: point.x + offset.dx, y: point.y + offset.dy))
    }
    func press(forDuration: TimeInterval, thenDragTo end: Coordinate,
               withVelocity: Match, thenHoldForDuration: TimeInterval) {
        app.scrolls += 1
        // A vertical drag stays inside the visible picker list.
        precondition(point.x == end.point.x && point.x >= 78 && point.x <= 796)
        precondition(point.y >= 24 && point.y <= 378 && end.point.y >= 24 && end.point.y <= 378)
        app.row.frame.origin.y += end.point.y - point.y
    }
}
extension Match { static var slow: Match { .any } }
struct Support {
    static func attachPickerDiagnostics(in app: App, details: String) {}
    static func waitUntilHittable(_ row: Element, timeout: TimeInterval) -> Bool { row.isHittable }
""" + wait + "\n    static func select(in app: App) {\n" + row + r"""
        tapRow(["On My iPhone"])
    }
}
var passed = true
for (name, frame, expectedScrolls) in [
    ("visible", CGRect(x: 78, y: 180, width: 718, height: 44), 0),
    ("home-indicator-clipped", CGRect(x: 78, y: 372, width: 718, height: 44), 1),
    ("recorded-landscape-clipped", CGRect(x: 78, y: 384.67, width: 718, height: 52), 1),
    ("top-clipped", CGRect(x: 78, y: -12, width: 718, height: 44), 1),
] {
    let app = App(frame)
    Support.select(in: app)
    let ok = app.row.accepted && app.row.taps == 1 && app.scrolls == expectedScrolls
    print(name, "accepted:", app.row.accepted, "taps:", app.row.taps, "scrolls:", app.scrolls)
    passed = passed && ok
}
// The recorded failure had frame snapshots taking about three seconds.
// Reading the same frame twice per sample exhausts the unchanged ten-second
// stabilization wait even when the row has already stopped moving.
let slow = App(CGRect(x: 78, y: 180, width: 718, height: 44))
slow.row.delayedStabilization = true
Support.select(in: slow)
print("slow stable row accepted:", slow.row.accepted, "frame reads:", slow.row.frameReads)
passed = passed && slow.row.accepted && slow.row.taps == 1
exit(passed && assertionFailures == 0 ? 0 : 1)
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
