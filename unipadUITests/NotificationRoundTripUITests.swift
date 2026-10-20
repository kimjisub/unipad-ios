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
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
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
        XCTAssertTrue(app.descendants(matching: .any)["main.packList"].waitForExistence(timeout: 15))

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
            card.tap()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "\(mode) notification did not bring the app forward")
            XCTAssertTrue(app.descendants(matching: .any)["main.packList"].waitForExistence(timeout: 20),
                          "pack list did not appear after \(mode) notification")
            UITestSupport.attachScreenshot("notification-\(mode)-pack-list", to: self)
            try Data().write(to: directory.appendingPathComponent("returned-\(mode)"), options: .atomic)
        }
    }
}
