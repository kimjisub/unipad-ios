"""Run the actual Swift visibility and scroll helpers against elements that vanish mid-check.

A lazy list can drop a row, or replace the empty-library scroll view with the pack list,
right after `exists` saw it. XCTest then fails the test on the next `frame` read. The fake
elements below answer `exists` a set number of times and then leave the accessibility tree.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SUPPORT = Path(__file__).resolve().parents[1] / "unipadUITests/UITestSupport.swift"


def probe_program(source):
    """A Swift program that exits 0 only when the helpers in `source` survive vanishing elements."""
    start = source.index("    static func isFullyVisible(")
    end = source.index("    /// Search exposes", start)
    visibility = source[start:end]
    start = source.index("    @discardableResult\n    static func scrollIntoView(")
    end = source.index("    /// The home screen's download", start)
    scrolling = source[start:end]
    helpers = (visibility + scrolling).replace("XCUIElement", "Element").replace("XCUIApplication", "App")
    return r"""
import CoreGraphics
import Foundation
var recordedFailures: [String] = []
enum Velocity { case slow }
struct Snapshot { let frame: CGRect }
struct SnapshotError: Error { let reason: String }
final class Element {
    let name: String
    let app: App?
    var storedFrame: CGRect
    // `exists` answers true this many times; the element is gone after the last one.
    var existsReadsLeft: Int
    var ambiguous = false
    init(_ name: String, _ frame: CGRect, app: App? = nil, existsReads: Int = Int.max) {
        self.name = name; self.app = app; storedFrame = frame; existsReadsLeft = existsReads
    }
    var isGone: Bool { existsReadsLeft == 0 }
    var exists: Bool {
        guard existsReadsLeft > 0 else { return false }
        existsReadsLeft -= 1
        return true
    }
    // XCTest records a failure, which ends the test, when a frame read finds no single match.
    var frame: CGRect {
        if isGone { recordedFailures.append("No matches found for \(name)"); return .zero }
        if ambiguous { recordedFailures.append("Multiple matching elements for \(name)") }
        return storedFrame
    }
    func snapshot() throws -> Snapshot {
        if isGone { throw SnapshotError(reason: "No matches found for \(name)") }
        if ambiguous { throw SnapshotError(reason: "Multiple matching elements for \(name)") }
        return Snapshot(frame: storedFrame)
    }
    func swipeUp(velocity: Velocity) { app?.scroll(by: -300) }
    func swipeDown(velocity: Velocity) { app?.scroll(by: 300) }
    func coordinate(withNormalizedOffset offset: CGVector) -> Coordinate {
        Coordinate(app: app!, point: storedFrame.origin)
    }
}
struct Query { let firstMatch: Element }
final class App {
    let windows = Query(firstMatch: Element("window", CGRect(x: 0, y: 0, width: 402, height: 874)))
    var content: [Element] = []
    func scroll(by distance: CGFloat) { for element in content { element.storedFrame.origin.y += distance } }
    func coordinate(withNormalizedOffset offset: CGVector) -> Coordinate { Coordinate(app: self, point: .zero) }
}
struct Coordinate {
    let app: App
    let point: CGPoint
    func withOffset(_ offset: CGVector) -> Coordinate {
        Coordinate(app: app, point: CGPoint(x: point.x + offset.dx, y: point.y + offset.dy))
    }
    func press(forDuration: TimeInterval, thenDragTo end: Coordinate,
               withVelocity: Velocity, thenHoldForDuration: TimeInterval) {
        app.scroll(by: end.point.y - point.y)
    }
}
struct Support {
""" + helpers + r"""
}
let listFrame = CGRect(x: 0, y: 100, width: 402, height: 700)
func screen(card cardFrame: CGRect, cardReads: Int = Int.max, listReads: Int = Int.max) -> (App, Element, Element) {
    let app = App()
    let card = Element("card", cardFrame, app: app, existsReads: cardReads)
    let list = Element("list", listFrame, app: app, existsReads: listReads)
    app.content = [card]
    return (app, card, list)
}
let onScreen = CGRect(x: 20, y: 400, width: 362, height: 80)
let belowFold = CGRect(x: 20, y: 760, width: 362, height: 80)
var passed = true
func check(_ name: String, _ result: Bool, expected: Bool, failures expectedFailures: Int = 0) {
    let ok = result == expected && recordedFailures.count == expectedFailures
    print(ok ? "PASS" : "FAIL", name, "result:", result, "failures:", recordedFailures)
    passed = passed && ok
    recordedFailures = []
}
do {
    let (app, card, list) = screen(card: onScreen)
    check("visible card", Support.isFullyVisible(card, in: app, within: list), expected: true)
}
do {
    let (app, card, list) = screen(card: onScreen, cardReads: 1)
    check("card leaves right after exists", Support.isFullyVisible(card, in: app, within: list), expected: false)
}
do {
    let (app, card, list) = screen(card: onScreen, listReads: 1)
    check("scroll view replaced right after exists", Support.isFullyVisible(card, in: app, within: list), expected: false)
}
do {
    let (app, card, list) = screen(card: belowFold)
    check("card below the fold is dragged into view", Support.scrollIntoView(card, in: list, app: app), expected: true)
}
do {
    // The visibility check reads the scroll view once; it is replaced right after the second read.
    let (app, card, list) = screen(card: belowFold, listReads: 2)
    check("scroll view replaced while scrolling", Support.scrollIntoView(card, in: list, app: app), expected: false)
}
do {
    let (app, card, list) = screen(card: onScreen)
    card.ambiguous = true
    check("a query matching several elements still fails", Support.isFullyVisible(card, in: app, within: list),
          expected: true, failures: 1)
}
exit(passed ? 0 : 1)
"""


def run_probe(source, directory):
    """Compiles and runs the probe in `directory`; returns (compiled, result)."""
    path = Path(directory)
    (path / "probe.swift").write_text(probe_program(source))
    compiled = subprocess.run(["xcrun", "swiftc", "-swift-version", "5",
        str(path / "probe.swift"), "-o", str(path / "probe")],
        capture_output=True, text=True, timeout=120)
    if compiled.returncode != 0:
        return compiled, None
    return compiled, subprocess.run([str(path / "probe")], capture_output=True, text=True, timeout=60)


class VanishingElementTests(unittest.TestCase):
    def test_helpers_answer_not_visible_when_an_element_vanishes_after_exists(self):
        scratch = os.environ.get("UNIPAD_TEST_TMPDIR") or os.environ.get("RUNNER_TEMP")
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            compiled, result = run_probe(SUPPORT.read_text(), directory)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            print(result.stdout, end="")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
