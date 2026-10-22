import XCTest

/// Opt in through ci/notification_roundtrip.py; notification permission needs a fresh install.
final class NotificationRoundTripUITests: XCTestCase {
    @MainActor
    func testPermissionAndNotificationLaunches() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let path = env["UNIPAD_NOTIFICATION_DIR"] else {
            throw XCTSkip("Run ci/notification_roundtrip.py on a lent simulator")
        }
        let directory = URL(fileURLWithPath: path)
        let token = try XCTUnwrap(env["UNIPAD_NOTIFICATION_TOKEN"])
        XCTAssertNotNil(UUID(uuidString: token))
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments()
        app.launch()
        let orientation = XCUIDevice.shared.orientation
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = orientation
        }
        // Evidence that the splash can be found at all, so its absence later means something.
        try Data("splash_seen=\(app.descendants(matching: .any)["splash"].exists ? "YES" : "NO")\n".utf8)
            .write(to: directory.appendingPathComponent("launched"), options: .atomic)
        waitForHome(in: app, after: "launch", withPacks: true)
        let list = UITestSupport.openStore(in: app, testCase: self)
        let row = UITestSupport.storeRows(in: list)
            .containing(NSPredicate(format: "label == %@", "Downloaded Fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["Download"].firstMatch.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "fresh install did not ask for notification permission")
        UITestSupport.attachScreenshot("notification-permission-before", to: self)
        let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "허용"])).firstMatch
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        // Tap the visible button, then require disappearance; tap() alone is not evidence.
        allow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 15), "permission alert remained after Allow")
        XCTAssertTrue(row.staticTexts["Downloaded"].waitForExistence(timeout: 30))
        UITestSupport.attachScreenshot("notification-permission-dismissed", to: self)
        UITestSupport.tapBack(in: app)
        waitForHome(in: app, after: "download", withPacks: true)

        for mode in ["background", "cold"] {
            if mode == "cold" {
                app.terminate()
                app.launchArguments = []
                XCTAssertEqual(app.state, .notRunning)
            } else {
                XCUIDevice.shared.press(.home)
                XCTAssertTrue(app.wait(for: .runningBackgroundSuspended, timeout: 15) || app.state == .runningBackground)
            }
            XCUIDevice.shared.orientation = .portrait
            // Open the retained list before delivery, avoiding the banner-to-center transition.
            let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.01))
            let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.9))
            top.press(forDuration: 0.1, thenDragTo: bottom)
            XCTAssertTrue(springboard.otherElements["combined-list-view"].waitForExistence(timeout: 10))
            try Data().write(to: directory.appendingPathComponent("ready-\(mode)"), options: .atomic)
            let pushed = directory.appendingPathComponent("pushed-\(mode)")
            let delivered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: pushed.path)
            }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [delivered], timeout: 30), .completed, "simctl push failed")

            let message = "UniPad \(mode) \(token)"
            let card = springboard.buttons.matching(identifier: "ListCell")
                .matching(NSPredicate(format: "label CONTAINS %@", message)).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 15), "synthetic notification missing from Notification Center")
            var previous = CGRect.null
            var stableSince = ProcessInfo.processInfo.systemUptime
            let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = card.frame
                let now = ProcessInfo.processInfo.systemUptime
                if frame != previous {
                    previous = frame
                    stableSince = now
                }
                return card.isHittable && now - stableSince >= 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [stable], timeout: 10), .completed, "notification card did not settle")
            UITestSupport.attachScreenshot("notification-\(mode)-received", to: self)
            let hierarchy = XCTAttachment(string: springboard.debugDescription)
            hierarchy.name = "notification-\(mode)-elements"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            // Use the notification's Open swipe action, never an app activation fallback.
            card.swipeRight(velocity: .slow)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "\(mode) notification did not bring the app forward")
            // The system starts the app without test arguments, so a cold launch opens the
            // test app's own library, which is empty; the download went to the isolated one.
            let splashSeen = waitForHome(in: app, after: "\(mode) notification", withPacks: mode == "background")
            UITestSupport.attachScreenshot("notification-\(mode)-home", to: self)
            try Data("splash_seen=\(splashSeen ? "YES" : "NO")\n".utf8)
                .write(to: directory.appendingPathComponent("returned-\(mode)"), options: .atomic)
        }
    }

    /// The launch splash is drawn over home, and home is in the element tree underneath
    /// it, so home's elements existing is no proof that home is on screen.
    /// Returns whether the splash was still up when the wait began.
    @MainActor
    @discardableResult
    private func waitForHome(in app: XCUIApplication, after step: String, withPacks: Bool) -> Bool {
        let splash = app.descendants(matching: .any)["splash"]
        let seen = splash.exists
        XCTAssertTrue(splash.waitForNonExistence(timeout: 20), "splash still covered home after \(step)")
        XCTAssertTrue(UITestSupport.waitUntilHittable(app.buttons["gearshape"], timeout: 20),
                      "home could not be touched after \(step)")
        if withPacks {
            XCTAssertTrue(UITestSupport.waitUntilHittable(app.scrollViews["main.packList"], timeout: 20),
                          "pack list could not be touched after \(step)")
        } else {
            XCTAssertTrue(UITestSupport.revealHomeCard(.download, in: app, timeout: 20).isHittable,
                          "empty library home could not be touched after \(step)")
        }
        return seen
    }
}
