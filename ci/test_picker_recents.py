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
typealias XCUIElement = Element
struct UITestSupport {
    static func filePickerRecents(in app: Picker) -> Element { Element(picker: app, back: false) }
    static func waitForFilePickerRecents(in app: Picker, timeout: TimeInterval) -> Element? {
        let element = filePickerRecents(in: app)
        return element.waitForExistence(timeout: timeout) ? element : nil
    }
    static func waitUntilHittable(_ element: Element, timeout: TimeInterval) -> Bool { element.exists }
    static func settledFilePickerCancelButton(in app: Picker, timeout: TimeInterval) -> Element? {
        // Model the existing helper's successful arrival and stable navigation bar.
        app.now += min(timeout, max(0, app.arrival - app.now))
        return app.ready ? Element(picker: app, back: false) : nil
    }
}
func navigate(_ app: Picker) throws -> Bool {
""" + navigation + r"""
    return recents?.exists == true && app.earlyBackReads == 0
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
        self.run_probe(program)

    def test_recents_can_be_a_phone_locations_row_or_tab(self):
        root = Path(__file__).resolve().parents[1]
        support = (root / "unipadUITests/UITestSupport.swift").read_text()
        start = support.index("    static func filePickerRecents(in app:")
        end = support.index("\n    }", start) + len("\n    }")
        selector = support[start:end]
        program = r"""
import Foundation
final class XCUIElement: NSObject {
    enum ElementType: Int { case any, button, cell, staticText, tabBar }
    @objc dynamic var elementType: Int
    @objc dynamic var label: String
    @objc dynamic var identifier: String
    var exists: Bool
    let children: [XCUIElement]
    init(_ type: ElementType, _ label: String = "", identifier: String = "",
         exists: Bool = true, children: [XCUIElement] = []) {
        elementType = type.rawValue; self.label = label; self.identifier = identifier
        self.exists = exists; self.children = children
    }
    var descendants: [XCUIElement] { children.flatMap { [$0] + $0.descendants } }
}
struct Query {
    let elements: [XCUIElement]
    var buttons: Query {
        Query(elements: elements.flatMap { $0.descendants }.filter {
            $0.elementType == XCUIElement.ElementType.button.rawValue
        })
    }
    var firstMatch: XCUIElement { elements.first(where: { $0.exists }) ?? XCUIElement(.any, exists: false) }
    func matching(_ predicate: NSPredicate) -> Query {
        Query(elements: elements.filter { predicate.evaluate(with: $0) })
    }
}
final class XCUIApplication {
    let elements: [XCUIElement]
    var cells: Query { descendants(matching: .cell) }
    var tabBars: Query { descendants(matching: .tabBar) }
    func descendants(matching type: XCUIElement.ElementType) -> Query {
        let all = elements.flatMap { [$0] + $0.descendants }
        return Query(elements: all.filter { type == .any || $0.elementType == type.rawValue })
    }
    init(_ elements: [XCUIElement]) { self.elements = elements }
}
enum UITestSupport {
    static var isPad = false
""" + selector + r"""
}
var passed = true
for language in ["Recents", "최근 항목"] {
    let file = XCUIElement(.cell, language, identifier: "DOC.item.\(language)")
    let fileButton = XCUIElement(.button, language, identifier: "DOC.item.\(language)")
    let tab = XCUIElement(.button, language)
    let tabBar = XCUIElement(.tabBar, children: [tab])
    let row = XCUIElement(.cell, language, identifier: "DOC.sidebar.item.\(language)")
    let title = XCUIElement(.staticText, language)
    let unrelated = XCUIElement(.cell, "Browse", identifier: "DOC.sidebar.item.Browse")
    for (name, elements, isPad, expected) in [
        ("phone-tab", [tabBar], false, tab),
        ("phone-locations-row", [row], false, row),
        ("ipad-sidebar", [row], true, row),
        ("file-before-phone-tab", [file, fileButton, tabBar], false, tab),
        ("file-before-phone-row", [file, fileButton, row], false, row),
        ("file-before-ipad-row", [file, fileButton, row], true, row),
        ("file-without-navigation", [file, fileButton], false, nil),
        ("ipad-file-without-navigation", [file, fileButton], true, nil),
        ("title-is-not-a-control", [title], false, nil),
        ("unrelated-row", [unrelated], false, nil),
    ] as [(String, [XCUIElement], Bool, XCUIElement?)] {
        UITestSupport.isPad = isPad
        let result = UITestSupport.filePickerRecents(in: XCUIApplication(elements))
        let correct = expected.map { result === $0 } ?? !result.exists
        print(language, name, "selected navigation only:", correct)
        passed = passed && correct
    }
}
exit(passed ? 0 : 1)
"""
        self.run_probe(program)

    def test_refreshes_recents_queries_after_back_and_row_transitions(self):
        root = Path(__file__).resolve().parents[1]
        support = (root / "unipadUITests/UITestSupport.swift").read_text()
        start = support.index("    static func filePickerRecents(in app:")
        end = support.index("    /// Clears system alerts", start)
        helpers = support[start:end]
        source = (root / "unipadUITests/FirstPackGuideTests.swift").read_text()
        start = source.index("        var recents", source.index("func testPreparedArchiveCanBeSelectedFromRecentItems"))
        end = source.index('        shot(Self.korean, "picker-recents")', start)
        navigation = source[start:end]
        program = r"""
import Foundation
var now: TimeInterval = 0
enum Failure: Error { case assertion }
var assertionsPassed = true
func XCTAssertTrue(_ value: Bool, _ message: String = "") { assertionsPassed = assertionsPassed && value }
func XCTAssertEqual<T: Equatable>(_ value: T, _ expected: T, _ message: String = "") {
    assertionsPassed = assertionsPassed && value == expected
}
func XCTUnwrap<T>(_ value: T?, _ message: String = "") throws -> T {
    guard let value else { throw Failure.assertion }
    return value
}
func shot() {}
final class XCTNSPredicateExpectation {
    let predicate: NSPredicate
    let object: Any?
    init(predicate: NSPredicate, object: Any?) { self.predicate = predicate; self.object = object }
}
struct XCTWaiter {
    enum Result { case completed, timedOut }
    func wait(for expectations: [XCTNSPredicateExpectation], timeout: TimeInterval) -> Result {
        let end = now + timeout
        repeat {
            if expectations.allSatisfy({ $0.predicate.evaluate(with: $0.object) }) { return .completed }
            now += 0.25
        } while now <= end
        return .timedOut
    }
}
final class XCUIElement: NSObject {
    enum ElementType { case button, cell, tabBar }
    let elementType: ElementType
    @objc dynamic let label: String
    @objc dynamic let identifier: String
    let present: () -> Bool
    let selected: () -> Bool
    let action: () -> Void
    let children: [XCUIElement]
    @objc dynamic var exists: Bool { present() }
    @objc dynamic var isSelected: Bool { exists && selected() }
    var isEnabled: Bool { exists }
    init(_ type: ElementType, _ label: String = "", identifier: String = "",
         present: @escaping () -> Bool = { true }, selected: @escaping () -> Bool = { false },
         action: @escaping () -> Void = {}, children: [XCUIElement] = []) {
        elementType = type; self.label = label; self.identifier = identifier
        self.present = present; self.selected = selected; self.action = action; self.children = children
    }
    var descendants: [XCUIElement] { children.flatMap { [$0] + $0.descendants } }
    func tap() { if exists { action() } }
    func waitForExistence(timeout: TimeInterval) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.exists }, object: nil)], timeout: timeout) == .completed
    }
}
struct Query {
    let resolve: () -> [XCUIElement]
    var buttons: Query { Query { resolve().flatMap { $0.descendants }.filter { $0.elementType == .button } } }
    var firstMatch: XCUIElement {
        // Model XCUITest's lazy query: the element can arrive later, but its query scope stays fixed.
        XCUIElement(resolve().first?.elementType ?? .cell,
            present: { self.resolve().contains(where: { $0.exists }) },
            selected: { self.resolve().first(where: { $0.exists })?.isSelected ?? false },
            action: { self.resolve().first(where: { $0.exists })?.tap() })
    }
    func matching(_ predicate: NSPredicate) -> Query {
        Query { resolve().filter { predicate.evaluate(with: $0) } }
    }
    subscript(_ identifier: String) -> XCUIElement {
        matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }
}
final class XCUIApplication {
    var elements: [XCUIElement] = []
    var cells: Query { Query { self.elements.filter { $0.elementType == .cell } } }
    var tabBars: Query { Query { self.elements.filter { $0.elementType == .tabBar } } }
    var buttons: Query { Query { self.elements.filter { $0.elementType == .button } } }
}
enum UITestSupport {
    static var isPad = false
    static func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool { element.exists }
""" + helpers + r"""
}
func navigate(_ app: XCUIApplication) throws {
""" + navigation.replace('shot(Self.korean, "picker-recents-missing")', "shot()") + r"""
}
var passed = true
for language in ["Recents", "최근 항목"] {
    for (name, backDelay, tabDelay, pad, missing) in [
        ("phone-row-to-immediate-tab", 0.0, 0.0, false, false),
        ("phone-row-to-late-tab", 0.0, 1.0, false, false),
        ("phone-back-to-late-tab", 1.0, 0.0, false, false),
        ("phone-back-to-later-tab", 3.0, 0.0, false, false),
        ("phone-back-to-late-row-and-tab", 1.0, 1.0, false, false),
        ("ipad-selected-sidebar", 0.0, 0.0, true, false),
        ("missing-tab-after-row", 0.0, 100.0, false, true),
    ] {
        now = 0; assertionsPassed = true; UITestSupport.isPad = pad
        var backed = backDelay == 0
        var rowTapped = false
        var tabTapped = false
        var backAt: TimeInterval = 0
        var rowAt: TimeInterval = 0
        let app = XCUIApplication()
        let back = XCUIElement(.button, identifier: "DOC.navBarButton.backInHistory",
            present: { !backed }, action: { backed = true; backAt = now })
        let row = XCUIElement(.cell, language, identifier: "DOC.sidebar.item.\(language)",
            present: { backed && now >= backAt + backDelay &&
                (!rowTapped || pad || now < rowAt + tabDelay) && (tabDelay > 0 || backDelay == 0 || pad) },
            selected: { rowTapped }, action: { rowTapped = true; rowAt = now })
        let tab = XCUIElement(.button, language,
            present: { !pad && backed && now >= backAt + backDelay &&
                ((backDelay > 0 && tabDelay == 0) || (rowTapped && now >= rowAt + tabDelay)) },
            selected: { rowTapped || tabTapped }, action: { tabTapped = true })
        let tabs = XCUIElement(.tabBar, children: [tab])
        // This file must never satisfy a wait, including while navigation is absent.
        let file = XCUIElement(.cell, language, identifier: "DOC.item.\(language)", selected: { true })
        app.elements = [file, back, row, tabs]
        do { try navigate(app) } catch { assertionsPassed = false }
        let correct = missing ? !assertionsPassed : assertionsPassed && (pad ? row.isSelected : tab.isSelected)
        print(language, name, "expected outcome:", correct, "elapsed:", now)
        passed = passed && correct
    }
}
exit(passed ? 0 : 1)
"""
        self.run_probe(program)

    def run_probe(self, program):
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
