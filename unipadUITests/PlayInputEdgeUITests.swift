import XCTest

/// Play screen input at its edges, through the real touch and pointer paths: a pad held while the
/// screen rotates, pointer presses, drags, clicks and a chain click (iPad), and pads with and
/// without `squareButton`. Each launch generates its packs in its own library ("Input Edges":
/// every pad of both chains loops a silent sample forever, no LEDs, so a pad shows the feedback
/// light only while it is held).
///
/// XCUITest has no API to hold one input while sending another, but it waits for a gesture by
/// running the main run loop, so a step on a run loop timer runs while an earlier press is still
/// down. Every such step is checked to have run before that press returned, and a picture
/// of the pads taken in the middle shows the press really held. Pictures and rotation work there;
/// a second gesture does not ("only one gesture can be performed at a time"), so these are not
/// covered on screen: two fingers, a pointer held with a finger in either order, and a finger
/// resting on the margin while a chain button is tapped. MultiTouchPlayTests covers two inputs
/// through the pad view (pointer presses arrive there as touches too, with no separate path).
/// Nor is an iPad window resized under a held pad: no public API resizes the window.
///
/// Not covered: sound. A UI test sees pixels only; the sound each finger starts and stops through
/// the same pad view is checked by MultiTouchPlayTests. Synthetic input, not physical fingers.
final class PlayInputEdgeUITests: XCTestCase {
    private let app = XCUIApplication()
    private var grid: XCUIElement { app.otherElements["playPadGrid"] }

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    @MainActor
    func testPadHeldWhileTheScreenRotatesLeavesNothingLit() throws {
        openPack("Input Edges")
        let idle = try settledPads()
        let held = (row: 2, col: 2)
        var heldBefore: [String] = [], heldAfter: [String] = []
        try whileHolding({ pad(held.row, held.col).press(forDuration: 5) }, steps: [
            Step(1.0, "picture before rotating") { heldBefore = try self.litPads(comparedWith: idle) },
            Step(1.5, "rotate") { XCUIDevice.shared.orientation = .landscapeRight },
            Step(3.5, "picture after rotating") { heldAfter = try self.litPads(comparedWith: idle) },
        ])
        XCTAssertEqual(heldBefore, ["3,3"], "the press was not down before the screen rotated")
        XCTAssertEqual(XCUIDevice.shared.orientation, .landscapeRight)
        // The system may cancel the touch when the screen rotates; either way the pad it held
        // must be the only one lit while it lasts.
        XCTAssertTrue(heldAfter == ["3,3"] || heldAfter == [], "pads lit while held after rotating: \(heldAfter)")
        UITestSupport.attachScreenshot("rotated-held-\(heldAfter.isEmpty ? "cancelled" : "kept")", to: self)
        try expectNoPadLit(comparedWith: idle, after: "lifting the pad held through the rotation")
        try expectOnlyPadLitWhilePressed(5, 6, comparedWith: idle, after: "rotating")
    }

    @MainActor
    func testPointerClicksDragsAndChangesChain() throws {
        try XCTSkipUnless(XCUIDevice.shared.supportsPointerInteraction, "only an iPad has a pointer")
        openPack("Input Edges")
        let idle = try settledPads()
        var during: [String] = []
        try whileHolding({ self.pad(4, 4).click(forDuration: 4, thenDragTo: self.pad(4, 4)) }, steps: [
            Step(1.5, "picture") { during = try self.litPads(comparedWith: idle) },
        ])
        XCTAssertEqual(during, ["5,5"], "a held pointer press did not light its pad alone")
        try expectNoPadLit(comparedWith: idle, after: "a pointer press")
        pad(3, 3).click(forDuration: 0.3, thenDragTo: pad(3, 6))
        try expectNoPadLit(comparedWith: idle, after: "a pointer drag across pads")
        pad(0, 0).click()
        try expectNoPadLit(comparedWith: idle, after: "a pointer click")
        let chain2 = chain(2)
        XCTAssertTrue(chain2.waitForExistence(timeout: 5))
        chain2.click()
        XCTAssertTrue(waitForSelected(chain2), "a pointer click did not select chain 2")
        XCTAssertFalse(chain(1).isSelected)
        try expectOnlyPadLitWhilePressed(2, 5, comparedWith: idle, after: "a pointer chain change")
    }

    /// `squareButton=false` packs are drawn and hit like `true` ones: PlayView sizes the grid from
    /// square cells (PlayLayoutTests checks the pad view's cells), so rectangular pads do not apply.
    @MainActor
    func testSquareButtonFalseDrawsTheSameGridAsTrue() throws {
        for size in ["8x8", "4x3"] {
            var frames: [CGRect] = []
            for shape in ["square", "rect"] {
                openPack("Grid \(size) \(shape)")
                frames.append(grid.frame)
                UITestSupport.attachScreenshot("grid-\(size)-\(shape)", to: self)
                app.terminate()
            }
            XCTAssertEqual(frames[0], frames[1], "\(size): squareButton=false moved or resized the pads")
            let columns: CGFloat = size == "8x8" ? 8 : 3, rows: CGFloat = size == "8x8" ? 8 : 4
            XCTAssertEqual(frames[1].width / columns, frames[1].height / rows, accuracy: 0.5, "\(size): pads are not square")
        }
    }

    // MARK: - Steps

    /// Something done at `at` seconds after a held input started.
    struct Step {
        let at: TimeInterval
        let name: String
        let run: @MainActor () throws -> Void
        init(_ at: TimeInterval, _ name: String, _ run: @escaping @MainActor () throws -> Void) {
            self.at = at
            self.name = name
            self.run = run
        }
    }

    @MainActor
    private final class StepLog {
        var ran: [String: TimeInterval] = [:]
        var failures: [Error] = []
    }

    /// Carries a main-thread step into a timer.
    private final class Fire: @unchecked Sendable {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    /// Runs `hold`, a gesture that blocks until it ends, and each step at its offset from the
    /// start while the gesture is still running. Fails when a step ran only after it ended, since
    /// then the hold did not overlap the step.
    @MainActor
    private func whileHolding(_ hold: @MainActor () -> Void,
                              steps: [Step]) throws {
        let start = Date()
        let log = StepLog()
        for step in steps {
            let fire = Fire {
                MainActor.assumeIsolated {
                    log.ran[step.name] = Date().timeIntervalSince(start)
                    do { try step.run() } catch { log.failures.append(error) }
                }
            }
            // A timer, unlike a main-queue block, also fires while another step is itself waiting
            // for a gesture, so a step can hold a second input.
            RunLoop.main.add(Timer(timeInterval: step.at, repeats: false) { _ in fire.run() }, forMode: .common)
        }
        hold()
        let ended = Date().timeIntervalSince(start)
        // Let steps the run loop could not reach during the hold run, so they are reported.
        let last = steps.map(\.at).max() ?? 0
        if last > ended { RunLoop.current.run(until: start.addingTimeInterval(last + 0.5)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        for step in steps {
            let at = try XCTUnwrap(log.ran[step.name], "step \(step.name) never ran")
            XCTAssertLessThan(at, ended, "step \(step.name) ran at \(at) s, after the held input ended at \(ended) s")
        }
        if let error = log.failures.first { throw error }
    }

    // MARK: - Helpers

    @MainActor
    private func openPack(_ title: String) {
        if app.launchArguments.isEmpty {
            var arguments = UITestSupport.englishLaunchArguments()
            if !arguments.contains("-UniPadReleaseTest") { arguments += ["-UniPadReleaseTest", UUID().uuidString] }
            app.launchArguments = arguments + ["-UniPadReleaseInputEdges", "YES"]
        }
        app.launch()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        UITestSupport.searchForPack(title, in: app)
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the \(title) pack was not prepared")
        row.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { row.tap() }
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        XCTAssertTrue(UITestSupport.waitForHiddenWindowsPillToGo(timeout: 30), "the system pill stayed over the pads")
    }

    @MainActor
    private func pad(_ row: Int, _ col: Int) -> XCUICoordinate {
        grid.coordinate(withNormalizedOffset: CGVector(dx: (CGFloat(col) + 0.5) / 8, dy: (CGFloat(row) + 0.5) / 8))
    }

    /// A chain button, whatever element type its traits give it.
    @MainActor
    private func chain(_ number: Int) -> XCUIElement {
        app.descendants(matching: .any)["playChain.\(number)"]
    }

    @MainActor
    private func waitForSelected(_ element: XCUIElement) -> Bool {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)
        return XCTWaiter().wait(for: [selected], timeout: 3) == .completed
    }

    /// Pads lit now, as "row,column" from 1. One picture, so a press is caught while it is held.
    @MainActor
    private func litPads(comparedWith idle: PadPixels) throws -> [String] {
        try PadPixels(grid.screenshot()).changedPads(comparedWith: idle)
    }

    /// The pads' pixels once two consecutive shots agree, so a fading press is not compared.
    @MainActor
    private func settledPads() throws -> PadPixels {
        var last = try PadPixels(grid.screenshot())
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let next = try PadPixels(grid.screenshot())
            if next.changedPads(comparedWith: last).isEmpty { return next }
            last = next
        }
        return last
    }

    @MainActor
    private func expectNoPadLit(comparedWith idle: PadPixels, after gesture: String) throws {
        let changed = try settledPads().changedPads(comparedWith: idle)
        if !changed.isEmpty { UITestSupport.attachScreenshot("lit-after-\(gesture)", to: self) }
        XCTAssertEqual(changed, [], "pads (row, column from 1) still lit after \(gesture)")
    }

    /// A new finger after `change` lights the pad under it and no other, and nothing stays lit.
    @MainActor
    private func expectOnlyPadLitWhilePressed(_ row: Int, _ col: Int, comparedWith idle: PadPixels, after change: String) throws {
        var lit: [String] = []
        try whileHolding({ self.pad(row, col).press(forDuration: 2.5) }, steps: [
            Step(1.2, "picture of the new press") { lit = try self.litPads(comparedWith: idle) },
        ])
        XCTAssertEqual(lit, ["\(row + 1),\(col + 1)"], "a new press after \(change) lit other pads")
        try expectNoPadLit(comparedWith: idle, after: "a new press after \(change)")
    }
}
