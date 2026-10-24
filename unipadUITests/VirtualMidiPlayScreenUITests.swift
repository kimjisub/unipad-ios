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
    func testFirstConnectionPrefersLaunchpadOverKeyboard() throws {
        _ = try openPlayScreen(device: "Test Keyboard", additionalDevices: ["Launchpad MK2"],
                               connectedAs: "Launchpad MK2", picture: "initial-device-priority")
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
    func testOpeningOptionsReleasesAControllerPadWhoseNoteOffIsHidden() throws {
        let idle = try openPlayScreen(device: "UniPad Test Keyboard", connectedAs: "Master Keyboard", picture: "options-release")
        try device.send(0x90, 36, 100)
        XCTAssertEqual(try waitForLitPads(["8,1"], comparedWith: idle, picture: "options-release-1-held"), ["8,1"])
        app.buttons["line.3.horizontal"].tap()
        let quit = app.buttons["Quit"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        try device.send(0x80, 36, 64)
        UITestSupport.attachScreenshot("options-release-2-hidden-note-off", to: self)
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: quit)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        XCTAssertEqual(try waitForLitPads([], comparedWith: idle, picture: "options-release-3-closed"), [],
                       "a note-off hidden by the options left the controller pad held")
    }

    @MainActor
    func testFingerReleaseStopsItsChainLightWhileTheControllerRemainsPressed() throws {
        _ = try openPlayScreen(device: "UniPad Test Keyboard", connectedAs: "Master Keyboard",
                                      picture: "separate-owners", archive: "InputOwners", packTitle: "Input Owners")
        app.buttons["line.3.horizontal"].tap()
        let quit = app.buttons["Quit"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        UITestSupport.setPlayOption("Feedback light", on: true, in: app)
        UITestSupport.setPlayOption("Trace Log", on: false, in: app)
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(quit.waitForNonExistence(timeout: 5))
        let idle = try PadPixels.settled(grid)
        try device.send(0x90, 36, 100)
        XCTAssertEqual(try waitForLitPads(["8,1", "8,2"], comparedWith: idle, picture: "separate-owners-1-controller"), ["8,1", "8,2"])
        app.descendants(matching: .any)["playChain.2"].tap()
        XCTAssertTrue(waitForSelectedChain(2, picture: "separate-owners-2-chain"))
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.9375)).press(forDuration: 0.4)
        XCTAssertEqual(try waitForLitPads(["8,1", "8,2"], comparedWith: idle, picture: "separate-owners-3-finger-released"), ["8,1", "8,2"],
                       "the finger's chain light outlived its release while the controller was held")
        try device.send(0x80, 36, 64)
        XCTAssertEqual(try waitForLitPads([], comparedWith: idle, picture: "separate-owners-4-controller-released"), [])
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
    private func openPlayScreen(
        device name: String, additionalDevices: [String] = [], connectedAs driver: String, picture: String,
        archive: String? = nil, packTitle: String = "Virtual MIDI"
    ) throws -> PadPixels {
        try device.run("open \(name)")
        for name in additionalDevices { try device.run("add \(name)") }
        if let archive {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("ExternalImportFixtures/\(archive).uni")
            app.launchArguments = UITestSupport.englishLaunchArguments(library: "chain-release", archive: try Data(contentsOf: url))
        } else {
            app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments() + ["-UniPadReleaseInputEdges", "YES"]
        }
        app.launch()
        UITestSupport.dismissSystemAlerts()
        let settings = app.buttons["gearshape"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let connected = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Connected: \(driver)")).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 15), "the app did not connect \(name) as \(driver)")
        UITestSupport.attachScreenshot("\(picture)-0-connected", to: self)
        UITestSupport.tapBack(in: app)
        UITestSupport.searchForPack(packTitle, in: app)
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", packTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "the \(packTitle) pack was not prepared")
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
