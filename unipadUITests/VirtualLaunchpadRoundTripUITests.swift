import XCTest

/// Run through ci/virtual_launchpad_roundtrip.py on a harness-lent simulator.
/// Virtual MK2 only: this does not test USB hardware, physical latency, or other models.
final class VirtualLaunchpadRoundTripUITests: XCTestCase {
    @MainActor
    func testRoundTrip() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let keys = ["UNIPAD_MIDI_ROUNDTRIP_DIR", "UNIPAD_MIDI_ROUNDTRIP_TOKEN", "UNIPAD_MIDI_ROUNDTRIP_ORDER"]
        guard keys.contains(where: { env[$0] != nil }) else {
            throw XCTSkip("Run ci/virtual_launchpad_roundtrip.py to configure the virtual MIDI check")
        }
        let path = try XCTUnwrap(env["UNIPAD_MIDI_ROUNDTRIP_DIR"])
        let token = try XCTUnwrap(env["UNIPAD_MIDI_ROUNDTRIP_TOKEN"])
        let order = try XCTUnwrap(env["UNIPAD_MIDI_ROUNDTRIP_ORDER"])
        XCTAssertTrue(path.hasPrefix("/"), "round-trip directory must be an absolute path")
        XCTAssertNotNil(UUID(uuidString: token), "round-trip token must identify an isolated fixture")
        XCTAssertTrue(["midi", "screen"].contains(order), "round-trip order must be midi or screen")
        let directory = URL(fileURLWithPath: path)
        let app = XCUIApplication()
        app.launchArguments = ["-UniPadFirebaseLocalOnly", "YES", "-UniPadReleaseTest", token,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        print("VIRTUAL-MIDI local_only=YES order=\(order) token=\(token)")
        app.launch()
        defer { app.terminate() }
        let home = app.buttons["gearshape"]
        XCTAssertTrue(home.waitForExistence(timeout: 30), "waiting for home")
        home.tap()
        let connected = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Connected: Launchpad MK2")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 15), "waiting for virtual Launchpad MK2 connection")
        let connection = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        connection.name = "virtual-mk2-connected"
        connection.lifetime = .keepAlways
        add(connection)
        UITestSupport.tapBack(in: app)
        let title = app.staticTexts["Virtual MIDI Fixture"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "waiting for isolated fixture")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 3) { play.tap() }
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "waiting for play grid")
        // The grid appears before loading completes; this control appears on the ready screen.
        XCTAssertTrue(app.buttons["line.3.horizontal"].waitForExistence(timeout: 15), "waiting for ready play screen")
        func tapScreen() {
            grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5 / 8, dy: 0.5 / 8)).tap()
            print("VIRTUAL-MIDI screen tap completed")
        }
        if order == "screen" { tapScreen() }
        try Data("ready".utf8).write(to: directory.appendingPathComponent("send"), options: .atomic)
        let response = directory.appendingPathComponent("midi-complete")
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: response.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 20), .completed,
                       "waiting for notes 81/82, releases, and LED replies")
        if order == "midi" { tapScreen() }
        // A second MIDI burst is unnecessary: both notes already arrived. Keep the log stream
        // open through the later screen input before the script checks for duplicate events.
        sleep(1)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "virtual-mk2-\(order)-first"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try Data("finished".utf8).write(to: directory.appendingPathComponent("ui-complete"), options: .atomic)
    }
}
