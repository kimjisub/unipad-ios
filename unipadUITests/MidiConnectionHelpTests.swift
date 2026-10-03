import XCTest

final class MidiConnectionHelpTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { try XCUIDevice.shared.voiceOverService.disable() }
        #endif
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments += UITestSupport.englishLaunchArguments()
        app.launchArguments += ["-LaunchpadConnectMethod", "0"]
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        app.buttons["gearshape"].tap()
        let reconnect = app.buttons["Reconnect Launchpad"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10))
        reconnect.tap()
    }

    override func tearDownWithError() throws {
        // XCTest assertions can abort a test without executing its Swift defer.
        // Always restore the device so later touch tests and workers are safe.
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { try XCUIDevice.shared.voiceOverService.disable() }
        #endif
    }

    private func waitSixSeconds() {
        let elapsed = expectation(description: "six seconds elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: 8)
    }

    @MainActor
    func testHelpStopsAutomaticReturnEvenAfterClosing() {
        let help = app.buttons["Connection and light help"]
        XCTAssertTrue(help.waitForExistence(timeout: 2), "help must be available before automatic return")
        help.tap()
        waitSixSeconds()
        let close = app.buttons["Close help"]
        XCTAssertTrue(close.exists)
        UITestSupport.attachScreenshot("help-after-six-seconds", to: self)
        close.tap()
        waitSixSeconds()
        XCTAssertTrue(help.exists, "closing help must not restart automatic return")
        UITestSupport.attachScreenshot("selection-six-seconds-after-help", to: self)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'OK'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Reconnect Launchpad"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUnusedHelpPreservesAutomaticReturn() {
        UITestSupport.attachScreenshot("selection-before-automatic-return", to: self)
        waitSixSeconds()
        XCTAssertTrue(app.buttons["Reconnect Launchpad"].waitForExistence(timeout: 3))
        UITestSupport.attachScreenshot("settings-after-automatic-return", to: self)
    }

    @MainActor
    func testSelectingModelStopsAutomaticReturn() {
        let model = app.buttons["Launchpad Mini MK3"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 2))
        model.tap()
        waitSixSeconds()
        XCTAssertTrue(model.exists)
        UITestSupport.attachScreenshot("explicit-selection-after-six-seconds", to: self)
    }

    @MainActor
    func testMiniGuideRequiresExplicitSelectionAndSurvivesBackgrounding() {
        let help = app.buttons["midi.help.open"]
        help.tap()
        XCTAssertFalse(app.buttons["Read the manufacturer's guide"].exists)
        app.buttons["midi.help.close"].tap()
        app.buttons["Launchpad Mini MK3"].firstMatch.tap()
        help.tap()
        let body = app.scrollViews["midi.help.body"]
        body.swipeUp()
        let guide = app.buttons["Read the manufacturer's guide"]
        XCTAssertTrue(guide.exists)
        XCTAssertTrue(app.staticTexts["midi.help.model"].label.contains("Launchpad Mini MK3"))
        UITestSupport.attachScreenshot("explicit-mini-guide", to: self)
        guide.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let browserOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
            object: safari
        )
        XCTAssertEqual(XCTWaiter().wait(for: [browserOpened], timeout: 10), .completed)
        app.activate()
        XCTAssertTrue(app.buttons["midi.help.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["midi.help.model"].label.contains("Launchpad Mini MK3"))
        XCTAssertFalse(app.staticTexts["midi.help.linkFailed"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["midi.help.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["midi.help.model"].label.contains("Launchpad Mini MK3"))
        app.buttons["midi.help.close"].tap()
        XCTAssertTrue(help.exists)
        let confirm = app.buttons["midi.confirm"]
        XCTAssertEqual(confirm.label, "OK")
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(confirm.frame))
        UITestSupport.tapOnScreen(confirm, in: app)
        XCTAssertTrue(app.buttons["Reconnect Launchpad"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testKoreanHelpAndLargeTextKeepHeaderAndActionsVisible() {
        app.terminate()
        app.launchArguments = UITestSupport.launchArguments(language: "ko", locale: "ko_KR")
        app.launchArguments += ["-LaunchpadConnectMethod", "0"]
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        app.buttons["gearshape"].tap()
        let reconnect = app.buttons["런치패드 다시 연결하기"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10))
        reconnect.tap()
        let help = app.buttons["midi.help.open"]
        let confirm = app.buttons["midi.confirm"]
        XCTAssertTrue(help.waitForExistence(timeout: 2))
        XCTAssertTrue(help.isHittable)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(help.frame))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(confirm.frame))
        XCTAssertTrue(confirm.label.hasPrefix("확인"))
        help.tap()
        app.buttons["midi.help.close"].tap()
        let longModel = app.buttons["Launchpad Pro (mat1jaczyyy CFW)"].firstMatch
        let models = app.scrollViews["midi.models"]
        for _ in 0..<3 where !longModel.isHittable { models.swipeUp() }
        XCTAssertTrue(longModel.isHittable)
        longModel.tap()
        help.tap()
        let close = app.buttons["midi.help.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        XCTAssertEqual(close.label, "도움말 닫기")
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(app.staticTexts["midi.help.title"].frame))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(app.staticTexts["midi.help.model"].frame))
        XCTAssertGreaterThanOrEqual(app.scrollViews["midi.help.body"].frame.height, 44)
        app.scrollViews["midi.help.body"].swipeUp()
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(app.staticTexts["midi.help.model"].exists)
        UITestSupport.attachScreenshot("korean-large-text-help", to: self)
        close.tap()
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(confirm.frame))
        UITestSupport.attachScreenshot("korean-large-text-selection", to: self)
        // Use the visible screen point, as the existing Settings back tests do:
        // on iOS 27 AX can report no activation point for a visible landscape button.
        UITestSupport.tapOnScreen(confirm, in: app)
        XCTAssertTrue(reconnect.waitForExistence(timeout: 5))
    }

    private func reopenSelection(language: String, rejectLink: Bool = false) {
        app.terminate()
        app.launchArguments = UITestSupport.launchArguments(
            language: language, locale: language == "ko" ? "ko_KR" : "en_US"
        ) + ["-LaunchpadConnectMethod", "0"]
        if rejectLink { app.launchArguments += ["-UniPadHelpRejectExternalURL"] }
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        app.buttons["gearshape"].tap()
        let reconnect = app.buttons[language == "ko" ? "런치패드 다시 연결하기" : "Reconnect Launchpad"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10))
        reconnect.tap()
    }

    @MainActor
    func testRejectedGuideKeepsHelpAndPendingSelection() {
        for language in ["en", "ko"] {
            reopenSelection(language: language, rejectLink: true)
            app.buttons["Launchpad Mini MK3"].firstMatch.tap()
            app.buttons["midi.help.open"].tap()
            app.scrollViews["midi.help.body"].swipeUp()
            let guide = app.buttons[language == "ko" ? "제조사 설명 보기" : "Read the manufacturer's guide"]
            XCTAssertTrue(guide.isHittable)
            guide.tap()
            let failure = app.staticTexts["midi.help.linkFailed"]
            XCTAssertTrue(failure.waitForExistence(timeout: 5))
            app.scrollViews["midi.help.body"].swipeUp()
            XCTAssertTrue(failure.isHittable)
            XCTAssertEqual(failure.label, language == "ko"
                ? "제조사 설명을 열 수 없어요. 이 도움말은 계속 읽을 수 있어요."
                : "Could not open the manufacturer's guide. You can continue reading this help.")
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertTrue(app.staticTexts["midi.help.model"].label.contains("Launchpad Mini MK3"))
            UITestSupport.attachScreenshot("rejected-guide-\(language)", to: self)
            app.buttons["midi.help.close"].tap()
            waitSixSeconds()
            XCTAssertTrue(app.buttons["midi.help.open"].exists)
            app.buttons["midi.help.open"].tap()
            XCTAssertTrue(app.staticTexts["midi.help.model"].label.contains("Launchpad Mini MK3"))
            app.buttons["midi.help.close"].tap()
            UITestSupport.tapOnScreen(app.buttons["midi.confirm"], in: app)
            XCTAssertTrue(app.buttons[language == "ko" ? "런치패드 다시 연결하기" : "Reconnect Launchpad"].waitForExistence(timeout: 5))
        }
    }

    #if compiler(>=6.4)
    @MainActor
    func testEscapeClosesOnlyHelpInBothLanguages() {
        for language in ["en", "ko"] {
            reopenSelection(language: language)
            app.buttons["midi.help.open"].tap()
            XCTAssertTrue(app.buttons["midi.help.close"].exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.buttons["midi.help.open"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["midi.help.close"].exists)
            waitSixSeconds()
            XCTAssertTrue(app.buttons["midi.help.open"].exists)
            UITestSupport.attachScreenshot("escape-closed-help-\(language)", to: self)
        }
    }

    #endif

    // VoiceOver automation is supplied by Xcode 27; older CI compilers keep
    // the existing UI tests without referencing symbols absent from their SDK.
    #if compiler(>=6.4)
    @MainActor
    func testVoiceOverReadsAndStaysInsideHelpInEnglish() throws {
        try checkVoiceOverHelp(language: "en")
    }

    @MainActor
    func testVoiceOverReadsAndStaysInsideHelpInKorean() throws {
        try checkVoiceOverHelp(language: "ko")
    }

    @MainActor
    private func checkVoiceOverHelp(language: String) throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver automation requires iOS 27") }
        let voiceOver = XCUIDevice.shared.voiceOverService
        defer { try? voiceOver.disable() }
        do {
            try voiceOver.disable()
            reopenSelection(language: language)
            app.buttons["midi.help.open"].tap()
            try voiceOver.enable()
            var speech = try voiceOver.currentSpeech().utterance
            var transcript = [speech]
            let title = language == "ko" ? "연결·불빛 도움말" : "Connection and light help"
            let model = language == "ko" ? "선택한 기종" : "Selected model"
            let close = language == "ko" ? "도움말 닫기" : "Close help"
            // Enabling VoiceOver in an already-open overlay may start in its
            // body. Read back to the fixed header before traversing forward.
            for _ in 0..<16 where !speech.contains(title) {
                speech = try voiceOver.moveBackward().utterance
                transcript.append(speech)
            }
            for _ in 0..<24 {
                speech = try voiceOver.moveForward().utterance
                transcript.append(speech)
                XCTAssertFalse(speech.contains("Reconnect Launchpad") || speech.contains("런치패드 다시 연결하기"))
                XCTAssertFalse(speech.hasPrefix("OK,") || speech.hasPrefix("확인,"))
            }
            let attachment = XCTAttachment(string: transcript.joined(separator: "\n"))
            attachment.name = "voiceover-speech-\(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertTrue(transcript.contains { $0.contains(title) }, transcript.joined(separator: "\n"))
            XCTAssertTrue(transcript.contains { $0.contains(model) && $0.contains("Launchpad S") })
            XCTAssertTrue(transcript.contains { $0.contains(close) })
            // Navigate back to the close control and activate the focused item
            // with VoiceOver's activation key, rather than tapping coordinates.
            for _ in 0..<24 where !speech.contains(close) {
                speech = try voiceOver.moveBackward().utterance
            }
            XCTAssertTrue(speech.contains(close))
            app.typeKey(" ", modifierFlags: [.control, .option])
            XCTAssertTrue(app.buttons["midi.help.open"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["midi.help.close"].exists, "VoiceOver activation must dismiss help")
            let returnedSpeech = try voiceOver.currentSpeech().utterance
            XCTAssertTrue(returnedSpeech.contains(title), "focus must return to help entry: \(returnedSpeech)")
            waitSixSeconds()
            XCTAssertTrue(app.buttons["midi.help.open"].exists)
            UITestSupport.attachScreenshot("voiceover-closed-help-\(language)", to: self)
            try voiceOver.disable()
        }
    }
    #endif

}
