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
        XCTAssertTrue(model.waitForExistence(timeout: 2),
                      "Test setup failed: model screen did not appear before automatic return")
        let confirm = app.buttons["midi.confirm"]
        UITestSupport.attachScreenshot("model-before-selection", to: self)
        guard model.isHittable, confirm.exists else {
            XCTFail("Test setup failed: automatic return left no model available for input")
            return
        }
        let modelFrame: CGRect
        let countdown: String
        do {
            modelFrame = try model.snapshot().frame
            countdown = try confirm.snapshot().label
        } catch {
            XCTFail("Test setup failed: model screen disappeared while preparing input: \(error)")
            return
        }
        // Leave time for XCTest to deliver the tap; do not restart the countdown.
        guard countdown.range(of: #"\([2-5]\)"#, options: .regularExpression) != nil else {
            XCTFail("Test setup failed: insufficient automatic-return time before input: \(countdown)")
            return
        }
        // Resolve the target before delivery. If automatic return wins the race,
        // a screen tap still completes and the preparation failure below explains it.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: modelFrame.midX, dy: modelFrame.midY)).tap()
        guard confirm.exists, model.exists else {
            UITestSupport.attachScreenshot("model-input-too-late", to: self)
            XCTFail("Test setup failed: automatic return finished before model input was accepted")
            return
        }
        // The first scroll view is the selected-device preview, outside the model grid.
        let preview = app.scrollViews.element(boundBy: 0).staticTexts["Launchpad Mini MK3"].firstMatch
        XCTAssertTrue(preview.exists, "Test setup failed: input was not confirmed as Launchpad Mini MK3 selection")
        XCTAssertEqual(confirm.label, "OK", "Model selection failed: automatic-return countdown was not cancelled")
        UITestSupport.attachScreenshot("model-after-selection", to: self)
        waitSixSeconds()
        XCTAssertTrue(model.exists, "Confirmed model selection did not stop automatic return")
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
        XCTAssertTrue(UITestSupport.scrollIntoView(longModel, in: models, app: app, maxSwipes: 3))
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

}
