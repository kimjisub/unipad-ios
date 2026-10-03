import XCTest

/// Help checks that need a real hardware key press. On the iOS simulator
/// XCTest's typeKey never sends Escape (the app receives no key event at all),
/// so these tests ask the host to press it through the simulator's HID input
/// instead. Run them with `ci/host-keys.sh`; without it they are skipped.
final class MidiHelpHardwareKeyTests: XCTestCase {
    private static let escape = "key 41"
    private var app: XCUIApplication!

    private struct Labels {
        let title, model, close, reconnect, confirm: String

        init(language: String) {
            let korean = language == "ko"
            title = korean ? "연결·불빛 도움말" : "Connection and light help"
            model = korean ? "선택한 기종" : "Selected model"
            close = korean ? "도움말 닫기" : "Close help"
            reconnect = korean ? "런치패드 다시 연결하기" : "Reconnect Launchpad"
            confirm = korean ? "확인" : "OK"
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard Self.hostKeysDirectory != nil else {
            throw XCTSkip("Needs a real key press from the host: run ci/host-keys.sh")
        }
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { try XCUIDevice.shared.voiceOverService.disable() }
        #endif
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDownWithError() throws {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { try XCUIDevice.shared.voiceOverService.disable() }
        #endif
    }

    private static var hostKeysDirectory: String? {
        ProcessInfo.processInfo.environment["HOST_KEYS_DIR"]
    }

    /// Asks ci/host-keys.sh to perform `axe batch` steps (one per line) and
    /// waits until the host reports them done.
    private func pressHostKeys(_ keys: String) {
        let dir = Self.hostKeysDirectory!
        let id = UUID().uuidString
        // Written aside and renamed so the host never reads a half-written request.
        let pending = "\(dir)/pending-\(id)"
        XCTAssertTrue(FileManager.default.createFile(atPath: pending, contents: Data(keys.utf8)))
        XCTAssertNoThrow(try FileManager.default.moveItem(atPath: pending, toPath: "\(dir)/request-\(id)"))
        let pressed = expectation(for: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: "\(dir)/done-\(id)")
        }, evaluatedWith: nil)
        wait(for: [pressed], timeout: 30)
    }

    private func waitSixSeconds() {
        let elapsed = expectation(description: "six seconds elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: 8)
    }

    /// Opens the Launchpad selection screen with Launchpad S saved, then the help.
    private func openHelp(language: String) -> Labels {
        let labels = Labels(language: language)
        app = XCUIApplication()
        app.launchArguments = UITestSupport.launchArguments(
            language: language, locale: language == "ko" ? "ko_KR" : "en_US"
        ) + ["-LaunchpadConnectMethod", "0"]
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        app.buttons["gearshape"].tap()
        XCTAssertTrue(app.buttons[labels.reconnect].waitForExistence(timeout: 10))
        app.buttons[labels.reconnect].tap()
        app.buttons["midi.help.open"].tap()
        XCTAssertTrue(app.buttons["midi.help.close"].waitForExistence(timeout: 5))
        return labels
    }

    private func assertOnlyHelpClosed(_ labels: Labels) {
        XCTAssertTrue(app.buttons["midi.help.open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["midi.help.close"].exists)
        XCTAssertTrue(app.buttons["midi.confirm"].exists, "Escape must close only the help")
        waitSixSeconds()
        XCTAssertTrue(app.buttons["midi.help.open"].exists, "the selection must stay after the help closes")
        XCTAssertFalse(app.buttons[labels.reconnect].exists)
    }

    @MainActor
    func testRealEscapeClosesOnlyHelpInBothLanguages() {
        for language in ["en", "ko"] {
            let labels = openHelp(language: language)
            UITestSupport.attachScreenshot("escape-before-\(language)", to: self)
            pressHostKeys(Self.escape)
            assertOnlyHelpClosed(labels)
            UITestSupport.attachScreenshot("escape-after-\(language)", to: self)
            app.terminate()
        }
    }

    // VoiceOver automation is supplied by Xcode 27; older compilers lack it.
    #if compiler(>=6.4)
    @MainActor
    func testVoiceOverReadsHelpAndEscapeReturnsFocusInEnglish() throws {
        try checkVoiceOver(language: "en")
    }

    @MainActor
    func testVoiceOverReadsHelpAndEscapeReturnsFocusInKorean() throws {
        try checkVoiceOver(language: "ko")
    }

    /// VoiceOver reads the help's title, selected model and close button, never
    /// leaves the help while moving through it, and after a real Escape on the
    /// close button its focus is back on the button that opened the help.
    ///
    /// The close button is reached but not activated: on the simulator VoiceOver
    /// receives none of its keyboard commands through the HID input (not even
    /// Control-Option-Right) and takes neither AXe's nor XCTest's double tap as
    /// an activation. Escape runs the same close as the button.
    @MainActor
    private func checkVoiceOver(language: String) throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver automation requires iOS 27") }
        let voiceOver = XCUIDevice.shared.voiceOverService
        let labels = openHelp(language: language)
        try voiceOver.enable()
        var speech = try voiceOver.currentSpeech().utterance
        var transcript = [speech]
        // Enabling VoiceOver over an open help may start in its body; read back
        // to the fixed header first.
        for _ in 0..<16 where !speech.contains(labels.title) {
            speech = try voiceOver.moveBackward().utterance
            transcript.append(speech)
        }
        for _ in 0..<24 {
            speech = try voiceOver.moveForward().utterance
            transcript.append(speech)
            XCTAssertFalse(speech.contains(labels.reconnect), "VoiceOver left the help: \(speech)")
            XCTAssertFalse(speech.hasPrefix(labels.confirm + ","), "VoiceOver left the help: \(speech)")
        }
        let text = transcript.joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = "voiceover-speech-\(language)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(transcript.contains { $0.contains(labels.title) }, text)
        XCTAssertTrue(transcript.contains { $0.contains(labels.model) && $0.contains("Launchpad S") }, text)
        XCTAssertTrue(transcript.contains { $0.contains(labels.close) }, text)
        UITestSupport.attachScreenshot("voiceover-help-\(language)", to: self)

        for _ in 0..<24 where !speech.contains(labels.close) {
            speech = try voiceOver.moveBackward().utterance
        }
        XCTAssertTrue(speech.contains(labels.close), "VoiceOver must be on the close button: \(speech)")
        pressHostKeys(Self.escape)
        XCTAssertTrue(app.buttons["midi.help.open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["midi.help.close"].exists, "Escape must close the help")
        XCTAssertTrue(app.buttons["midi.confirm"].exists)
        let returned = try voiceOver.currentSpeech().utterance
        let focus = XCTAttachment(string: returned)
        focus.name = "voiceover-focus-after-escape-\(language)"
        focus.lifetime = .keepAlways
        add(focus)
        XCTAssertTrue(returned.contains(labels.title) && !returned.contains(labels.close),
                      "focus must return to the help button: \(returned)")
        waitSixSeconds()
        XCTAssertTrue(app.buttons["midi.help.open"].exists)
        XCTAssertEqual(try voiceOver.currentSpeech().utterance, returned)
        UITestSupport.attachScreenshot("voiceover-after-escape-\(language)", to: self)
        try voiceOver.disable()
    }
    #endif
}
