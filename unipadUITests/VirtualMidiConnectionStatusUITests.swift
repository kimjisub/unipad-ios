import XCTest

/// The Launchpad selection screen's status, model source and help with devices that ci/midi-input-tests.sh
/// publishes in the simulator's MIDI server (ci/virtual-midi-device.c). Skipped unless that script runs it.
/// A virtual endpoint has no USB device behind it, so its endpoint name is the name it reports.
/// Not covered: real Launchpads and their firmware.
final class VirtualMidiConnectionStatusUITests: XCTestCase {
    private let app = XCUIApplication()
    private var device: VirtualMidiDevice!

    private struct Labels {
        let korean: Bool
        init(_ language: String) { korean = language == "ko" }
        var reconnect: String { korean ? "런치패드 다시 연결하기" : "Reconnect Launchpad" }
        func connected(_ name: String) -> String { (korean ? "연결됨: " : "Connected: ") + name }
        var waiting: String { korean ? "아무 패드나 눌러 보세요. 신호가 오면 여기에 표시돼요." : "Press any pad. You'll see it here when a signal arrives." }
        var longWait: String { korean ? "아직 패드 신호가 없어요. 눌러도 그대로라면 '연결이 안 되나요?'를 봐 주세요." : "No pad signal yet. If pressing doesn't change this, tap “Not connecting?”." }
        var received: String { korean ? "패드 신호를 받았어요." : "Pad signal received." }
        var disconnected: String { korean ? "연결이 끊겼어요" : "Disconnected" }
        var unknownTag: String { korean ? "기종 모름" : "Model unknown" }
        var automatic: String { korean ? "자동으로 알아봄" : "Recognised automatically" }
        var manual: String { korean ? "직접 고름 · 다시 꽂으면 자동으로 돌아가요" : "Chosen by you · resets when you plug in again" }
        var openFailed: String { korean ? "장치를 열지 못했어요" : "Couldn't open the device" }
        func firmware(_ name: String) -> String { (korean ? "커스텀 펌웨어: " : "Custom firmware: ") + name }
        var ok: String { korean ? "확인" : "OK" }
    }

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["UNIPAD_VIRTUAL_MIDI_DIR"] else {
            throw XCTSkip("Run ci/midi-input-tests.sh to publish virtual MIDI devices")
        }
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .landscapeLeft
        device = try VirtualMidiDevice(folder: URL(fileURLWithPath: path))
    }

    override func tearDownWithError() throws {
        app.terminate()
        try device?.run("close")
    }

    private var status: XCUIElement { app.descendants(matching: .any)["midi.status"] }
    private var source: XCUIElement { app.staticTexts["midi.model.source"] }
    private var confirm: XCUIElement { app.buttons["midi.confirm"] }

    /// Opens the selection screen with `name` plugged in, then stops the countdown through the help
    /// unless `keepCountdown`, so the screen stays for the following steps.
    @discardableResult
    private func openSelection(with name: String?, language: String = "en", extra: [String] = [],
                               keepCountdown: Bool = false) throws -> Labels {
        let labels = Labels(language)
        if let name { try device.run("open \(name)") } else { try device.run("close") }
        app.launchArguments = UITestSupport.launchArguments(
            language: language, locale: language == "ko" ? "ko_KR" : "en_US"
        ) + ["-LaunchpadConnectMethod", "0"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        XCTAssertTrue(UITestSupport.waitUntilHittable(app.buttons["gearshape"], timeout: 5))
        UITestSupport.tapOnScreen(app.buttons["gearshape"], in: app)
        XCTAssertTrue(app.buttons[labels.reconnect].waitForExistence(timeout: 10))
        app.buttons[labels.reconnect].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        if !keepCountdown, confirm.label != labels.ok {
            openHelp()
            closeHelp()
        }
        return labels
    }

    /// A tap on the help's close button while it is still appearing can be lost, so each step waits.
    private func openHelp() {
        app.buttons["midi.help.open"].tap()
        XCTAssertTrue(app.buttons["midi.help.close"].waitForExistence(timeout: 3), "the help opens")
    }

    private func closeHelp() {
        let close = app.buttons["midi.help.close"]
        XCTAssertTrue(UITestSupport.waitUntilHittable(close, timeout: 3))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3), "the help closes")
    }

    private func waitForStatus(containing text: String, timeout: TimeInterval = 10) -> Bool {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.status.exists && self.status.label.contains(text)
        }, object: nil)
        let ok = XCTWaiter().wait(for: [shown], timeout: timeout) == .completed
        if !ok { XCTFail("status never showed \(text); it shows \(status.exists ? status.label : "nothing")") }
        return ok
    }

    private func waitSixSeconds() {
        let elapsed = expectation(description: "six seconds elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: 8)
    }

    /// Every state the screen shows for a recognised Launchpad, pictured in both languages.
    @MainActor
    func testRecognisedLaunchpadWalkInBothLanguages() throws {
        for language in ["en", "ko"] {
            let labels = try openSelection(with: "Launchpad MK2", language: language)
            XCTAssertTrue(waitForStatus(containing: labels.connected("Launchpad MK2")))
            XCTAssertTrue(status.label.contains(labels.waiting), status.label)
            XCTAssertEqual(source.label, labels.automatic)
            UITestSupport.attachScreenshot("\(language)-connected-before-input", to: self)

            openHelp()
            XCTAssertTrue(app.staticTexts["midi.help.status"].label.hasSuffix(labels.connected("Launchpad MK2")))
            XCTAssertTrue(app.staticTexts["midi.help.model"].label.hasSuffix("Launchpad MK2 · " + labels.automatic))
            XCTAssertTrue(app.staticTexts[labels.korean ? "고른 뒤 '확인'을 눌러야 적용돼요." : "Tap OK to apply your choice."].exists,
                          "the 'pressing does nothing' question opens first")
            UITestSupport.attachScreenshot("\(language)-help-connected-before-input", to: self)
            closeHelp()

            try device.send(0x90, 81, 100)
            try device.send(0x90, 81, 0)
            XCTAssertTrue(waitForStatus(containing: labels.received))
            UITestSupport.attachScreenshot("\(language)-pad-signal-received", to: self)

            try device.run("close")
            XCTAssertTrue(waitForStatus(containing: labels.disconnected))
            XCTAssertFalse(source.exists, "no source once the device is gone")
            XCTAssertEqual(confirm.label, labels.ok)
            UITestSupport.attachScreenshot("\(language)-disconnected", to: self)
            // The disconnect banner stays for four seconds over every screen. The help opens below
            // it and stays put when it goes, so Close is never covered or moved from under a tap.
            openHelp()
            let banner = app.staticTexts["midi.banner.message"]
            XCTAssertTrue(banner.exists, "the disconnect banner is still shown")
            let closeFrame = app.buttons["midi.help.close"].frame
            XCTAssertGreaterThanOrEqual(closeFrame.minY, banner.frame.maxY, "the banner covers Close")
            UITestSupport.attachScreenshot("\(language)-help-disconnected", to: self)
            XCTAssertTrue(banner.waitForNonExistence(timeout: 8), "the banner goes away")
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(app.buttons["midi.help.close"].frame, closeFrame, "Close moved when the banner went")
            closeHelp()

            try device.run("open Launchpad MK2")
            XCTAssertTrue(waitForStatus(containing: labels.waiting), "input resets on reconnection")
            XCTAssertEqual(source.label, labels.automatic)
            UITestSupport.attachScreenshot("\(language)-reconnected", to: self)
            app.terminate()
        }
    }

    @MainActor
    func testRecognisedLaunchpadKeepsAutomaticConfirmation() throws {
        let labels = try openSelection(with: "Launchpad MK2", keepCountdown: true)
        // The button reads its title and the seconds left as one label: "OK, (4)".
        XCTAssertTrue(confirm.label.hasPrefix(labels.ok + ", ("), confirm.label)
        UITestSupport.attachScreenshot("countdown", to: self)
        waitSixSeconds()
        XCTAssertTrue(app.buttons[labels.reconnect].waitForExistence(timeout: 3), "the screen confirms after five seconds")
    }

    @MainActor
    func testChoosingAModelByHandStopsConfirmationAndResetsOnReplug() throws {
        let labels = try openSelection(with: "Launchpad MK2", keepCountdown: true)
        app.buttons["Launchpad Mini MK3"].firstMatch.tap()
        XCTAssertEqual(source.label, labels.manual)
        XCTAssertEqual(confirm.label, labels.ok)
        UITestSupport.attachScreenshot("chosen-by-hand", to: self)
        waitSixSeconds()
        XCTAssertTrue(confirm.exists)
        XCTAssertFalse(status.label.contains("Custom firmware"))
        app.buttons["Launchpad Pro (Launchpad Open)"].firstMatch.tap()
        XCTAssertFalse(status.label.contains("Custom firmware"), "choosing a firmware card by hand is not recognition")

        try device.run("close")
        XCTAssertTrue(waitForStatus(containing: labels.disconnected))
        try device.run("open Launchpad MK2")
        XCTAssertTrue(waitForStatus(containing: labels.connected("Launchpad MK2")))
        XCTAssertEqual(source.label, labels.automatic)
        XCTAssertTrue(app.scrollViews.element(boundBy: 0).staticTexts["Launchpad MK2"].exists)
    }

    @MainActor
    func testLongWaitIsNotShownAsAFailure() throws {
        let labels = try openSelection(with: "Launchpad MK2")
        XCTAssertTrue(waitForStatus(containing: labels.longWait, timeout: 25))
        UITestSupport.attachScreenshot("long-wait", to: self)
        try device.send(0xB0, 104, 127)
        try device.send(0xB0, 104, 0)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(status.label.contains(labels.longWait), "a top-row button is not a pad press")
    }

    @MainActor
    func testUnknownDeviceInBothLanguages() throws {
        for language in ["en", "ko"] {
            let labels = try openSelection(with: "Test Synth", language: language, keepCountdown: true)
            XCTAssertTrue(waitForStatus(containing: labels.connected("Test Synth")))
            XCTAssertTrue(status.label.contains(labels.unknownTag), status.label)
            XCTAssertEqual(confirm.label, labels.ok, "no automatic confirmation for an unknown model")
            XCTAssertFalse(source.exists)
            UITestSupport.attachScreenshot("\(language)-unknown-model", to: self)
            app.buttons["Launchpad Mini MK3"].firstMatch.tap()
            XCTAssertEqual(source.label, labels.manual)
            UITestSupport.attachScreenshot("\(language)-unknown-model-chosen-by-hand", to: self)
            openHelp()
            UITestSupport.attachScreenshot("\(language)-help-unknown-model", to: self)
            app.terminate()
        }
    }

    @MainActor
    func testRecognisedCustomFirmwareInBothLanguages() throws {
        for language in ["en", "ko"] {
            let labels = try openSelection(with: "Pro (MIDI)", language: language)
            XCTAssertTrue(waitForStatus(containing: labels.firmware("CoreFW")))
            XCTAssertEqual(source.label, labels.automatic)
            try device.send(0x90, 81, 100)
            XCTAssertTrue(waitForStatus(containing: labels.received))
            UITestSupport.attachScreenshot("\(language)-custom-firmware-input", to: self)
            openHelp()
            XCTAssertTrue(app.buttons["midi.help.cfwLink"].waitForExistence(timeout: 3),
                          "the custom firmware question opens first")
            UITestSupport.attachScreenshot("\(language)-help-custom-firmware", to: self)
            app.terminate()
        }
    }

    @MainActor
    func testDeviceThatCannotBeOpenedInBothLanguages() throws {
        for language in ["en", "ko"] {
            let labels = try openSelection(with: "Launchpad X", language: language, extra: ["-UniPadMidiRefuseOpen"],
                                           keepCountdown: true)
            XCTAssertTrue(waitForStatus(containing: labels.openFailed))
            XCTAssertTrue(status.label.contains("Launchpad X · "), status.label)
            XCTAssertEqual(confirm.label, labels.ok)
            XCTAssertFalse(source.exists)
            UITestSupport.attachScreenshot("\(language)-open-failed", to: self)
            app.terminate()
        }
    }
}
