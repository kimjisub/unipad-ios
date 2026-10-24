import XCTest

final class PlaybackLightsUITests: XCTestCase {
    @MainActor
    func testRectangularPackLightsRemainVisible() throws {
        try checkHeldPad(pack: "RectangularLights", expectsGreen: true)
    }

    @MainActor
    func testRectangularPackWithoutLightsKeepsPressFeedback() throws {
        try checkHeldPad(pack: "RectangularFeedback", expectsGreen: false)
    }

    @MainActor
    func testPressFeedbackWinsOverPackLightsOnScreen() throws {
        try checkHeldPad(pack: "PressedLight", expectsGreen: false, enableFeedback: true)
    }

    @MainActor
    private func checkHeldPad(pack: String, expectsGreen: Bool, enableFeedback: Bool = false) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("ExternalImportFixtures/\(pack).uni")
        let app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments(library: "chain-release", archive: try Data(contentsOf: url))
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 20))
        UITestSupport.searchForPack(pack, in: app)
        let title = app.staticTexts[pack].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 20))
        if enableFeedback {
            app.buttons["line.3.horizontal"].tap()
            let feedback = app.switches["Feedback light"]
            XCTAssertTrue(feedback.waitForExistence(timeout: 5))
            feedback.tap()
            app.buttons["line.3.horizontal"].tap()
        }
        let idle = try PadPixels.settled(grid)
        UITestSupport.attachScreenshot("\(pack)-before-press", to: self)
        let capture = HeldCapture()
        let began = ProcessInfo.processInfo.systemUptime
        let duration = 5.0
        let fire = Fire {
            MainActor.assumeIsolated {
                capture.started = ProcessInfo.processInfo.systemUptime - began
                let shot = grid.screenshot()
                let attachment = XCTAttachment(screenshot: shot)
                attachment.name = "\(pack)-while-held"
                attachment.lifetime = .keepAlways
                self.add(attachment)
                capture.pixels = try? PadPixels(shot)
                capture.completed = ProcessInfo.processInfo.systemUptime - began
            }
        }
        let timer = Timer(timeInterval: 1.0, repeats: false) { _ in fire.run() }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625)).press(forDuration: duration)
        let returned = ProcessInfo.processInfo.systemUptime - began
        UITestSupport.attachScreenshot("\(pack)-after-release", to: self)
        let held = try XCTUnwrap(capture.pixels)
        let timing = HeldInputTiming(started: capture.started, completed: capture.completed)
        XCTAssertTrue(timing.finishedWhileHeld(duration: duration, commandReturned: returned),
                      "capture started=\(capture.started), completed=\(capture.completed), returned=\(returned)")
        XCTAssertEqual(held.changedPads(comparedWith: idle), ["1,1"])
        let color = held.means[0]
        if expectsGreen {
            XCTAssertGreaterThan(color[1], color[0] + 30, "the pack's green light must remain visible")
        } else {
            XCTAssertLessThanOrEqual(color[1] - color[0], 20, "the pack's green light covered the pressed appearance")
        }
        XCTAssertEqual(try PadPixels.settled(grid).changedPads(comparedWith: idle), [])
    }

    private final class HeldCapture: @unchecked Sendable {
        var started = -1.0
        var completed = -1.0
        var pixels: PadPixels?
    }

    /// The timer fires on the main run loop, where its callback enters the main actor.
    private final class Fire: @unchecked Sendable {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
}
