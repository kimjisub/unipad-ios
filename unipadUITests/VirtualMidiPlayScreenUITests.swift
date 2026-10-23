import XCTest

/// What a MIDI device's presses, releases and chain buttons show on the play screen, from devices
/// that ci/midi-input-tests.sh publishes in the simulator's MIDI server (ci/virtual-midi-device.c).
/// Every step leaves a screenshot named after it. Skipped unless that script runs it.
///
/// The "Virtual MIDI" pack loops a silent sample on every pad and has no LEDs, so a pad shows the
/// feedback light only while it is held. A virtual endpoint connects as port 0; a device's second
/// port travels in the Universal MIDI Packet group. Not covered: USB hardware and its port order.
final class VirtualMidiPlayScreenUITests: XCTestCase {
    private let app = XCUIApplication()
    private var device: VirtualMidiDevice!
    private var grid: XCUIElement { app.otherElements["playPadGrid"] }

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["UNIPAD_VIRTUAL_MIDI_DIR"] else {
            throw XCTSkip("Run ci/midi-input-tests.sh to publish virtual MIDI devices")
        }
        // Each step is reported and pictured even after an earlier one fails.
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
        device = try VirtualMidiDevice(folder: URL(fileURLWithPath: path))
    }

    override func tearDownWithError() throws {
        app.terminate()
        try device?.run("close")
    }

    @MainActor
    func testLaunchpadProMK3SecondPortPressesReleasesAndSelectsAChain() throws {
        let idle = try openPlayScreen(device: "LPProMK3 MIDI", connectedAs: "Launchpad Pro MK3", picture: "pro-mk3")
        try device.send(0x90, 81, 100, port: 1)
        XCTAssertEqual(try waitForLitPads(["1,1"], comparedWith: idle, picture: "pro-mk3-1-note-on"), ["1,1"],
                       "a note on from the second port did not press the top-left pad")
        try device.send(0x90, 81, 0, port: 1)
        XCTAssertEqual(try waitForLitPads([], comparedWith: idle, picture: "pro-mk3-2-note-on-velocity-0"), [],
                       "a note on with velocity 0 from the second port did not release the pad")
        try device.send(0xB0, 79, 127, port: 1)
        XCTAssertTrue(waitForSelectedChain(2, picture: "pro-mk3-3-chain-2"),
                      "the second right-hand button did not select chain 2")
    }

    @MainActor
    func testKeyboardReleasesOnNoteOffWithVelocityAndIgnoresAftertouch() throws {
        let idle = try openPlayScreen(device: "UniPad Test Keyboard", connectedAs: "Master Keyboard", picture: "keyboard")
        try device.send(0x90, 36, 100)
        XCTAssertEqual(try waitForLitPads(["8,1"], comparedWith: idle, picture: "keyboard-1-note-on"), ["8,1"],
                       "the lowest key did not press the bottom-left pad")
        try device.send(0xA0, 36, 0)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(try litPads(comparedWith: idle, picture: "keyboard-2-aftertouch-0"), ["8,1"],
                       "aftertouch easing off released the pad")
        try device.send(0x80, 36, 64)
        XCTAssertEqual(try waitForLitPads([], comparedWith: idle, picture: "keyboard-3-note-off-velocity-64"), [],
                       "a note off with a release velocity left the pad pressed")
        // Again without aftertouch first, which could have released the pad on its own.
        try device.send(0x90, 37, 100)
        XCTAssertEqual(try waitForLitPads(["8,2"], comparedWith: idle, picture: "keyboard-4-second-key-on"), ["8,2"],
                       "the second key did not press the next pad")
        try device.send(0x80, 37, 64)
        XCTAssertEqual(try waitForLitPads([], comparedWith: idle, picture: "keyboard-5-second-key-off-velocity-64"), [],
                       "a note off with a release velocity left the second pad pressed")
    }

    @MainActor
    func testMatrixReleasesOnVelocityZeroAndSelectsRingChains() throws {
        let idle = try openPlayScreen(device: "Matrix Test", connectedAs: "Mystrix", picture: "matrix")
        try device.send(0x90, 36, 100)
        XCTAssertEqual(try waitForLitPads(["8,1"], comparedWith: idle, picture: "matrix-1-note-on"), ["8,1"],
                       "the bottom-left note did not press the bottom-left pad")
        try device.send(0x90, 36, 0)
        XCTAssertEqual(try waitForLitPads([], comparedWith: idle, picture: "matrix-2-note-on-velocity-0"), [],
                       "a note on with velocity 0 left the pad pressed")
        for (step, (note, chain)) in [(UInt32(101), 2), (123, 9), (116, 16), (115, 17), (108, 24)].enumerated() {
            try device.send(0x90, note, 127)
            XCTAssertTrue(waitForSelectedChain(chain, picture: "matrix-\(step + 3)-ring-note-\(note)-chain-\(chain)"),
                          "ring note \(note) did not select chain \(chain)")
            try device.send(0x90, note, 0)
        }
    }

    /// Publishes `device`, launches the app, shows that it connected, and opens the pack. Returns
    /// the idle pads to compare later pictures with.
    @MainActor
    private func openPlayScreen(device name: String, connectedAs driver: String, picture: String) throws -> PadPixels {
        try device.run("open \(name)")
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments() + ["-UniPadReleaseInputEdges", "YES"]
        app.launch()
        UITestSupport.dismissSystemAlerts()
        let settings = app.buttons["gearshape"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let connected = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Connected: \(driver)")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 15), "the app did not connect \(name) as \(driver)")
        UITestSupport.attachScreenshot("\(picture)-0-connected", to: self)
        app.buttons["chevron.left"].firstMatch.tap()
        UITestSupport.searchForPack("Virtual MIDI", in: app)
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Virtual MIDI")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the Virtual MIDI pack was not prepared")
        row.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { row.tap() }
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        // The grid appears before loading completes; this control appears on the ready screen.
        XCTAssertTrue(app.buttons["line.3.horizontal"].waitForExistence(timeout: 15), "the play screen did not get ready")
        XCTAssertTrue(UITestSupport.waitForHiddenWindowsPillToGo(timeout: 30), "the system pill stayed over the pads")
        return try PadPixels.settled(grid)
    }

    /// Pads lit now, as "row,column" from 1, with a picture of the whole screen.
    @MainActor
    private func litPads(comparedWith idle: PadPixels, picture: String) throws -> [String] {
        let lit = try PadPixels(grid.screenshot()).changedPads(comparedWith: idle)
        UITestSupport.attachScreenshot(picture, to: self)
        return lit
    }

    @MainActor
    private func waitForLitPads(_ expected: [String], comparedWith idle: PadPixels, picture: String) throws -> [String] {
        let deadline = Date().addingTimeInterval(3)
        var lit = try PadPixels(grid.screenshot()).changedPads(comparedWith: idle)
        while lit != expected && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            lit = try PadPixels(grid.screenshot()).changedPads(comparedWith: idle)
        }
        // A pad that stays lit or dark is pictured as it is a moment later, not only at the first look.
        Thread.sleep(forTimeInterval: 0.3)
        return try litPads(comparedWith: idle, picture: picture)
    }

    @MainActor
    private func waitForSelectedChain(_ number: Int, picture: String) -> Bool {
        let chain = app.descendants(matching: .any)["playChain.\(number)"]
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: chain)
        let result = XCTWaiter().wait(for: [selected], timeout: 3) == .completed
        UITestSupport.attachScreenshot(picture, to: self)
        return result
    }
}
