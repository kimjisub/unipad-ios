"""Exercise the actual Recents navigation while the picker arrives late."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class PickerRecentsTests(unittest.TestCase):
    def test_waits_for_restored_picker_before_inspecting_navigation(self):
        source = (Path(__file__).resolve().parents[1] / "unipadUITests/FirstPackGuideTests.swift").read_text()
        start = source.index("    func testPreparedArchiveCanBeSelectedFromRecentItems()")
        start = source.index("UITestSupport.revealHomeCard(.import, in: app).tap()", start)
        start = source.index("\n", start)
        end = source.index("        let foundRecents", start)
        navigation = source[start:end]
        program = r"""
import Foundation
enum Missing: Error { case element }
func XCTUnwrap<T>(_ value: T?, _ message: String = "") throws -> T {
    guard let value else { throw Missing.element }
    return value
}
func XCTAssertTrue(_ value: Bool, _ message: String = "") { precondition(value, message) }
final class Picker {
    var now: TimeInterval = 0
    let arrival: TimeInterval
    var depth: Int
    let sidebar: Bool
    var earlyBackReads = 0
    init(arrival: TimeInterval, depth: Int, sidebar: Bool) {
        self.arrival = arrival; self.depth = depth; self.sidebar = sidebar
    }
    var ready: Bool { now >= arrival }
    var buttons: Picker { self }
    subscript(_ identifier: String) -> Element { Element(picker: self, back: true) }
}
struct Element {
    let picker: Picker
    let back: Bool
    var exists: Bool {
        if back {
            if !picker.ready { picker.earlyBackReads += 1 }
            return picker.ready && picker.depth > 0
        }
        return picker.ready && (picker.sidebar || picker.depth == 0)
    }
    var isEnabled: Bool { exists }
    func waitForExistence(timeout: TimeInterval) -> Bool {
        if exists { return true }
        picker.now += timeout
        return exists
    }
    func tap() { if back && exists { picker.depth -= 1 } }
}
struct UITestSupport {
    static func filePickerRecents(in app: Picker) -> Element { Element(picker: app, back: false) }
    static func waitUntilHittable(_ element: Element, timeout: TimeInterval) -> Bool { element.exists }
    static func settledFilePickerCancelButton(in app: Picker, timeout: TimeInterval) -> Element? {
        // Model the existing helper's successful arrival and stable navigation bar.
        app.now += min(timeout, max(0, app.arrival - app.now))
        return app.ready ? Element(picker: app, back: false) : nil
    }
}
func navigate(_ app: Picker) throws -> Bool {
""" + navigation + r"""
    return recents.exists && app.earlyBackReads == 0
}
var passed = true
for (name, arrival, depth, sidebar) in [
    ("phone-restored-folder-late", 8.0, 3, false),
    ("phone-restored-folder-ready", 0.0, 3, false),
    ("phone-locations-late", 8.0, 0, false),
    ("ipad-sidebar-late", 8.0, 3, true),
] {
    let app = Picker(arrival: arrival, depth: depth, sidebar: sidebar)
    let result = try navigate(app)
    print(name, "reached Recents:", result, "early back reads:", app.earlyBackReads)
    passed = passed && result
}
let missing = Picker(arrival: 100, depth: 3, sidebar: false)
var rejectedMissing = false
do { _ = try navigate(missing) } catch { rejectedMissing = true }
print("missing-picker rejected:", rejectedMissing, "early back reads:", missing.earlyBackReads)
passed = passed && rejectedMissing && missing.earlyBackReads == 0
exit(passed ? 0 : 1)
"""
        developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
        frameworks = str(Path(developer) / "Platforms/MacOSX.platform/Developer/Library/Frameworks")
        scratch = os.environ.get("UNIPAD_TEST_TMPDIR") or os.environ.get("RUNNER_TEMP")
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            path = Path(directory)
            (path / "probe.swift").write_text(program)
            compiled = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-F", frameworks,
                "-Xlinker", "-rpath", "-Xlinker", frameworks,
                str(path / "probe.swift"), "-o", str(path / "probe")],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(path / "probe")], capture_output=True, text=True, timeout=20)
            print(result.stdout, end="", flush=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
