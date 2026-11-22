import XCTest

/// The Launchpad selection screen and its help without a device connected. The connected states,
/// with virtual MIDI devices, are in VirtualMidiConnectionStatusUITests.
final class MidiConnectionHelpTests: XCTestCase {
    private var app: XCUIApplication!

    private struct Labels {
        let help, close, reconnect, noDevice, noDeviceNext, now, model, web, customFirmware, linkFailed: String
        let questions: [String]

        init(language: String) {
            let korean = language == "ko"
            help = korean ? "연결이 안 되나요?" : "Not connecting?"
            close = korean ? "도움말 닫기" : "Close help"
            reconnect = korean ? "런치패드 다시 연결하기" : "Reconnect Launchpad"
            noDevice = korean ? "런치패드를 찾지 못했어요" : "No Launchpad found"
            noDeviceNext = korean ? "케이블·어댑터·전원을 확인하고 다시 꽂아 주세요."
                : "Check the cable, adapter and power, then plug it in again."
            now = korean ? "지금 상태: " : "Now: "
            model = korean ? "선택한 기종: " : "Selected model: "
            web = korean ? "웹에서 자세히 보기" : "Read the full guide on the web"
            customFirmware = korean ? "커스텀 펌웨어 안내 보기" : "Read about custom firmware"
            linkFailed = korean ? "웹 안내를 열 수 없어요. 이 도움말은 계속 볼 수 있어요."
                : "Couldn't open the web guide. You can keep reading this help."
            questions = korean
                ? ["런치패드를 찾지 못해요", "연결됐는데 눌러도 반응이 없어요", "소리는 나는데 불빛이 없어요",
                   "누른 자리와 다른 패드가 반응해요", "오른쪽 버튼으로 체인이 안 바뀌어요", "커스텀 펌웨어를 써요", "앱이 종료돼요"]
                : ["The app can't find the Launchpad", "Connected, but pressing pads does nothing",
                   "Sound plays, but no lights", "The wrong pad responds", "Right-side buttons don't change chains",
                   "I use custom firmware", "The app closes unexpectedly"]
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { try XCUIDevice.shared.voiceOverService.disable() }
        #endif
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        // XCTest assertions can abort a test without executing its Swift defer.
        // Always restore the device so later touch tests and workers are safe.
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { try XCUIDevice.shared.voiceOverService.disable() }
        #endif
    }

    @discardableResult
    private func openSelection(language: String, rejectLink: Bool = false, extra: [String] = []) -> Labels {
        let labels = Labels(language: language)
        app.terminate()
        app.launchArguments = UITestSupport.launchArguments(
            language: language, locale: language == "ko" ? "ko_KR" : "en_US"
        ) + ["-LaunchpadConnectMethod", "0"] + extra
        if rejectLink { app.launchArguments += ["-UniPadHelpRejectExternalURL"] }
        app.launch()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        XCTAssertTrue(UITestSupport.waitUntilHittable(app.buttons["gearshape"], timeout: 5))
        UITestSupport.tapOnScreen(app.buttons["gearshape"], in: app)
        let reconnect = app.buttons[labels.reconnect]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10))
        reconnect.tap()
        XCTAssertTrue(app.buttons["midi.help.open"].waitForExistence(timeout: 5))
        return labels
    }

    private func waitSixSeconds() {
        let elapsed = expectation(description: "six seconds elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: 8)
    }

    private var helpBody: XCUIElement { app.scrollViews["midi.help.body"] }

    private func question(_ number: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "midi.help.q\(number)").firstMatch
    }

    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(UITestSupport.scrollIntoView(element, in: helpBody, app: app, maxSwipes: 8),
                      "\(element) did not come into view")
    }

    @MainActor
    func testNoDeviceShowsWhatToDoAndNeverConfirmsByItself() {
        for language in ["en", "ko"] {
            let labels = openSelection(language: language)
            let status = app.descendants(matching: .any)["midi.status"]
            XCTAssertTrue(status.waitForExistence(timeout: 2))
            XCTAssertEqual(status.label, "\(labels.noDevice), \(labels.noDeviceNext)")
            XCTAssertFalse(app.staticTexts["midi.model.source"].exists, "no source without a device")
            let confirm = app.buttons["midi.confirm"]
            XCTAssertEqual(confirm.label, language == "ko" ? "확인" : "OK")
            XCTAssertEqual(app.buttons["midi.help.open"].label, labels.help)
            UITestSupport.attachScreenshot("no-device-\(language)", to: self)
            waitSixSeconds()
            XCTAssertTrue(confirm.exists, "the screen must not close by itself without a device")
            XCTAssertEqual(confirm.label, language == "ko" ? "확인" : "OK")
            XCTAssertFalse(app.buttons[labels.reconnect].exists)
            UITestSupport.tapOnScreen(confirm, in: app)
            XCTAssertTrue(app.buttons[labels.reconnect].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testHelpListsSevenQuestionsWithTheMatchingOneOpen() {
        for language in ["en", "ko"] {
            let labels = openSelection(language: language)
            app.buttons["midi.help.open"].tap()
            XCTAssertTrue(app.buttons["midi.help.close"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["midi.help.title"].label, labels.help)
            XCTAssertEqual(app.staticTexts["midi.help.status"].label, labels.now + labels.noDevice)
            XCTAssertEqual(app.staticTexts["midi.help.model"].label, labels.model + "Launchpad S")
            let first = app.staticTexts[language == "ko"
                ? "• 케이블을 끝까지 꽂고, 휴대폰 단자에 맞는 어댑터를 써 주세요. 다른 케이블로도 바꿔 보세요."
                : "• Push the cable all the way in and use an adapter that fits your phone. Try another cable too."]
            XCTAssertTrue(first.exists, "the question for 'no device' must be open")
            let secondLine = app.staticTexts[language == "ko"
                ? "고른 뒤 '확인'을 눌러야 적용돼요." : "Tap OK to apply your choice."]
            XCTAssertFalse(secondLine.exists, "only one question opens first")
            UITestSupport.attachScreenshot("help-no-device-\(language)", to: self)

            for (index, title) in labels.questions.enumerated() {
                let row = question(index + 1)
                reveal(row)
                XCTAssertTrue(row.label.contains(title), "question \(index + 1): \(row.label)")
            }
            reveal(app.buttons["midi.help.web"])
            XCTAssertEqual(app.buttons["midi.help.web"].label, labels.web)
            XCTAssertFalse(app.buttons["Read the manufacturer's guide"].exists)
            XCTAssertFalse(app.buttons["제조사 설명 보기"].exists)

            reveal(question(2))
            question(2).tap()
            XCTAssertTrue(secondLine.waitForExistence(timeout: 3), "a closed question opens when pressed")
            UITestSupport.attachScreenshot("help-second-question-open-\(language)", to: self)
            app.buttons["midi.help.close"].tap()
            XCTAssertTrue(app.buttons["midi.help.close"].waitForNonExistence(timeout: 3))
            XCTAssertTrue(app.buttons["midi.confirm"].exists)
        }
    }

    @MainActor
    func testWebGuideOpensSafariAndHelpSurvivesReturn() {
        let labels = openSelection(language: "en")
        app.buttons["midi.help.open"].tap()
        reveal(question(5))
        question(5).tap()
        let chainStep = app.staticTexts["Check in this order."]
        XCTAssertTrue(chainStep.waitForExistence(timeout: 3))
        let web = app.buttons["midi.help.web"]
        reveal(web)
        UITestSupport.attachScreenshot("web-guide-before-open", to: self)
        web.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let browserOpened = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue),
            object: safari
        )
        XCTAssertEqual(XCTWaiter().wait(for: [browserOpened], timeout: 10), .completed)
        app.activate()
        XCTAssertTrue(app.buttons["midi.help.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(chainStep.exists, "the opened question stays open after returning")
        XCTAssertFalse(app.staticTexts["midi.help.linkFailed"].exists)
        XCTAssertEqual(app.staticTexts["midi.help.status"].label, labels.now + labels.noDevice)
        UITestSupport.attachScreenshot("web-guide-after-return", to: self)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["midi.help.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(chainStep.exists)
        app.buttons["midi.help.close"].tap()
        XCTAssertTrue(app.buttons["midi.help.open"].exists)
        XCTAssertEqual(app.buttons["midi.confirm"].label, "OK")
    }

    @MainActor
    func testRejectedGuideKeepsHelpAndPendingSelection() {
        for language in ["en", "ko"] {
            let labels = openSelection(language: language, rejectLink: true)
            app.buttons["Launchpad Mini MK3"].firstMatch.tap()
            app.buttons["midi.help.open"].tap()
            XCTAssertTrue(app.staticTexts["midi.help.model"].label.hasSuffix("Launchpad Mini MK3"))
            reveal(question(6))
            question(6).tap()
            let firmwareLink = app.buttons["midi.help.cfwLink"]
            reveal(firmwareLink)
            XCTAssertEqual(firmwareLink.label, labels.customFirmware)
            firmwareLink.tap()
            let failure = app.staticTexts["midi.help.linkFailed"]
            XCTAssertTrue(failure.waitForExistence(timeout: 5))
            reveal(failure)
            XCTAssertEqual(failure.label, labels.linkFailed)
            XCTAssertEqual(app.state, .runningForeground)
            UITestSupport.attachScreenshot("rejected-firmware-guide-\(language)", to: self)

            let web = app.buttons["midi.help.web"]
            reveal(web)
            web.tap()
            XCTAssertTrue(failure.waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts.matching(identifier: "midi.help.linkFailed").count, 1,
                           "the failure shows under the link that failed")
            UITestSupport.attachScreenshot("rejected-web-guide-\(language)", to: self)
            app.buttons["midi.help.close"].tap()
            app.buttons["midi.help.open"].tap()
            XCTAssertTrue(app.staticTexts["midi.help.model"].label.hasSuffix("Launchpad Mini MK3"))
            app.buttons["midi.help.close"].tap()
            UITestSupport.tapOnScreen(app.buttons["midi.confirm"], in: app)
            XCTAssertTrue(app.buttons[labels.reconnect].waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testKoreanHelpAndLargeTextKeepHeaderAndActionsVisible() {
        let labels = openSelection(language: "ko", extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        let help = app.buttons["midi.help.open"]
        let confirm = app.buttons["midi.confirm"]
        // The status fills the column at this size; the help button follows it in the same scroll.
        XCTAssertTrue(UITestSupport.scrollIntoView(help, in: app.scrollViews["midi.selection.column"], app: app,
                                                   maxSwipes: 4), "the help button is reached by scrolling")
        XCTAssertTrue(help.isHittable)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(help.frame))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(confirm.frame))
        XCTAssertTrue(confirm.label.hasPrefix("확인"))
        UITestSupport.attachScreenshot("korean-large-text-no-device", to: self)
        let longModel = app.buttons["Launchpad Pro (Launchpad Open)"].firstMatch
        let models = app.scrollViews["midi.models"]
        XCTAssertTrue(UITestSupport.scrollIntoView(longModel, in: models, app: app, maxSwipes: 3))
        longModel.tap()
        help.tap()
        let close = app.buttons["midi.help.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        XCTAssertEqual(close.label, labels.close)
        XCTAssertTrue(close.isHittable)
        for header in ["midi.help.title", "midi.help.status", "midi.help.model"] {
            XCTAssertTrue(app.windows.firstMatch.frame.contains(app.staticTexts[header].frame), header)
        }
        XCTAssertEqual(app.staticTexts["midi.help.model"].label, labels.model + "Launchpad Pro (Launchpad Open)")
        XCTAssertGreaterThanOrEqual(helpBody.frame.height, 44)
        helpBody.swipeUp()
        XCTAssertTrue(close.isHittable)
        UITestSupport.attachScreenshot("korean-large-text-help", to: self)
        close.tap()
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(confirm.frame))
        UITestSupport.attachScreenshot("korean-large-text-selection", to: self)
        // Use the visible screen point, as the existing Settings back tests do:
        // on iOS 27 AX can report no activation point for a visible landscape button.
        UITestSupport.tapOnScreen(confirm, in: app)
        XCTAssertTrue(app.buttons[labels.reconnect].waitForExistence(timeout: 5))
    }

    /// The smallest landscape iPhone screen, 667 by 375 points, in an iPad window of that size: the
    /// status, the help button and OK stay inside it, also with the largest text, and so does the
    /// help's header with its Close button. A landscape iPad window stays at least 486 points tall,
    /// so the iPad is held upright, where the landscape-only app lies on its side and a window 375
    /// wide and 667 tall shows it 667 by 375. Element frames come from snapshots, in the app's own
    /// landscape coordinates, so they are compared with the window's snapshot, never its `frame`.
    @MainActor
    func testSmallLandscapeWindowKeepsStatusHelpAndOKInside() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "only an iPad window can be resized")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        defer {
            // iPadOS remembers a window size per orientation, so the upright one is restored too.
            UITestSupport.resizeWindow(of: app, to: XCUIScreen.main.screenshot().image.size)
            app.terminate()
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
        }
        let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        let cases: [(name: String, language: String, extra: [String])] = [
            ("en", "en", []), ("ko", "ko", []), ("ko-large-text", "ko", largeText),
        ]
        for (name, language, extra) in cases {
            let labels = openSelection(language: language, extra: extra)
            UITestSupport.resizeWindow(of: app, to: CGSize(width: 375, height: 667))
            let window = try app.windows.firstMatch.snapshot().frame
            XCTAssertEqual(window.width, 667, accuracy: 30, "\(window)")
            XCTAssertEqual(window.height, 375, accuracy: 30, "\(window)")
            let status = app.descendants(matching: .any)["midi.status"]
            XCTAssertTrue(status.waitForExistence(timeout: 3))
            XCTAssertTrue(status.label.contains(labels.noDevice), status.label)
            XCTAssertTrue(UITestSupport.isFullyVisible(app.buttons["midi.confirm"], in: app), "\(name): OK outside \(window)")
            // The largest text makes the status taller than the column; it then scrolls with the
            // model, with the help button right after it, and starts at the top of the window.
            let statusFrame = try status.snapshot().frame
            if extra.isEmpty {
                XCTAssertTrue(UITestSupport.isFullyVisible(status, in: app), "\(name): \(statusFrame) outside \(window)")
            } else {
                XCTAssertTrue(window.contains(statusFrame.origin), "\(name): \(statusFrame) starts outside \(window)")
                XCTAssertGreaterThan(statusFrame.height, window.height / 2, "\(name): the status did not grow")
            }
            add(Self.windowShot("small-window-\(name)-selection", app: app))
            if !extra.isEmpty {
                // Drags in this upright window do not scroll the column reliably, so the largest text
                // checks only that the help button follows the status in the same scroll; reaching it
                // by scrolling is checked on the iPhone.
                let helpFrame = try app.buttons["midi.help.open"].snapshot().frame
                XCTAssertGreaterThanOrEqual(helpFrame.minY, statusFrame.maxY - 1, "\(name): \(helpFrame) before the status")
                continue
            }
            XCTAssertTrue(UITestSupport.isFullyVisible(app.buttons["midi.help.open"], in: app),
                          "\(name): the help button outside \(window)")

            app.buttons["midi.help.open"].tap()
            let close = app.buttons["midi.help.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            for header in [app.staticTexts["midi.help.title"], close, app.staticTexts["midi.help.status"]] {
                XCTAssertTrue(UITestSupport.isFullyVisible(header, in: app), "\(name): \(header) outside \(window)")
            }
            XCTAssertTrue(app.staticTexts["midi.help.status"].label.hasSuffix(labels.noDevice))
            add(Self.windowShot("small-window-\(name)-help", app: app))
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        }
    }

    private static func windowShot(_ name: String, app: XCUIApplication) -> XCTAttachment {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        return shot
    }

    // VoiceOver automation is supplied by Xcode 27; older compilers lack it.
    #if compiler(>=6.4)
    /// VoiceOver reads the status first, then the help button, the selected model and OK, before the model list.
    @MainActor
    func testVoiceOverReadsStatusBeforeHelpModelAndList() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver automation requires iOS 27") }
        try checkVoiceOverOrder(name: "voiceover-selection")
    }

    /// At the largest text size the status and the help button scroll with the model, read in the same order.
    @MainActor
    func testVoiceOverKeepsTheOrderAtTheLargestTextSize() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver automation requires iOS 27") }
        try checkVoiceOverOrder(name: "voiceover-selection-largest-text",
                                extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    @available(iOS 27.0, *)
    @MainActor
    private func checkVoiceOverOrder(name: String, extra: [String] = []) throws {
        let voiceOver = XCUIDevice.shared.voiceOverService
        for language in ["en", "ko"] {
            let labels = openSelection(language: language, extra: extra)
            if !voiceOver.isEnabled { try voiceOver.enable() }
            var speech = try VoiceOverReading.firstSpeech { try voiceOver.moveForward().utterance }
            var transcript = [speech]
            for _ in 0..<12 where !speech.contains(labels.noDevice) {
                speech = try voiceOver.moveBackward().utterance
                transcript.append(speech)
            }
            var order = [speech]
            for _ in 0..<6 {
                speech = try voiceOver.moveForward().utterance
                order.append(speech)
            }
            let text = order.joined(separator: "\n")
            let attachment = XCTAttachment(string: "reached by:\n" + transcript.joined(separator: "\n")
                                           + "\n\nreading order:\n" + text)
            attachment.name = "\(name)-order-\(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
            func position(_ needle: String) -> Int? { order.firstIndex { $0.contains(needle) } }
            // VoiceOver automation cuts an utterance short, so the next step is matched by its start.
            let status = position(labels.noDevice), next = position(String(labels.noDeviceNext.prefix(20)))
            let help = position(labels.help), model = position("Launchpad S")
            let confirm = position(language == "ko" ? "확인" : "OK"), list = position("Launchpad MK2")
            XCTAssertEqual(status, 0, text)
            XCTAssertEqual(next, 0, "the status is one element: \(text)")
            XCTAssertEqual(help, 1, text)
            XCTAssertEqual(model, 2, text)
            XCTAssertNotNil(confirm, text)
            if let confirm, let list { XCTAssertLessThan(confirm, list, text) }
            UITestSupport.attachScreenshot("\(name)-\(language)", to: self)
            // The next language opens the screen by taps, which VoiceOver would only focus.
            try voiceOver.disable()
            app.terminate()
        }
    }
    #endif
}
