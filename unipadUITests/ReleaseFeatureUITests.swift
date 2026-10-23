import notify
import XCTest

/// Release basic features that no other UI test reaches: opening a pack downloaded from the
/// store, pausing autoplay, and locking the screen during play.
/// Every launch gets its own generated library and fixture store answers (ReleaseTestSupport).
final class ReleaseFeatureUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    @MainActor
    func testStoreDownloadedPackOpens() {
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.englishLaunchArguments(library: "empty", isolated: true)
        app.launch()
        defer { app.terminate() }
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        let list = UITestSupport.openStore(in: app, testCase: self)
        let row = UITestSupport.storeRows(in: list)
            .containing(NSPredicate(format: "label == %@", "Downloaded Fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        app.buttons["Download"].firstMatch.tap()
        UITestSupport.dismissSystemAlerts()
        XCTAssertTrue(row.staticTexts["Downloaded"].waitForExistence(timeout: 30), "the store pack was not installed")
        UITestSupport.attachScreenshot("store-pack-downloaded", to: self)
        UITestSupport.tapBack(in: app)
        UITestSupport.openPack(titled: "Downloaded Fixture", in: app,
                               missingMessage: "the downloaded pack is not in the library")
    }

    /// The transport button's icon is what a user sees; the runner's position while paused is
    /// checked by the unit tests of AutoPlayRunner and PlaybackStop.
    @MainActor
    func testAutoplayPausesResumesAndStops() {
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments()
        app.launch()
        defer { app.terminate() }
        UITestSupport.openPack(titled: "Release Fixture - Tests", in: app,
                               missingMessage: "the release fixture was not prepared")
        chooseMode("Autoplay", in: app)
        let pause = app.buttons["pause.fill"]
        let resume = app.buttons["play.fill"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "autoplay did not start")
        pause.tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "autoplay did not pause")
        XCTAssertFalse(pause.exists)
        UITestSupport.attachScreenshot("autoplay-paused", to: self)
        resume.tap()
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "autoplay did not resume")
        chooseMode("Autoplay", in: app)
        XCTAssertTrue(pause.waitForNonExistence(timeout: 5), "choosing Autoplay again must stop it")
        XCTAssertFalse(resume.exists)
        UITestSupport.attachScreenshot("autoplay-stopped", to: self)
    }

    /// Locks the screen while a long sound plays and unlocks it again. The play screen still being
    /// there afterwards means the app was neither terminated nor relaunched.
    @MainActor
    func testLockingTheScreenDuringPlayKeepsTheSession() throws {
        let app = XCUIApplication()
        app.launchArguments = UITestSupport.isolatedLibraryLaunchArguments() + ["-UniPadReleaseRepeat", "YES"]
        app.launch()
        defer { app.terminate() }
        UITestSupport.openPack(titled: "Release Fixture - Tests", in: app,
                               missingMessage: "the release fixture was not prepared")
        let grid = app.otherElements["playPadGrid"]
        let firstPad = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.0625, dy: 0.0625))
        firstPad.tap()

        let lockState = try LockState()
        // A failure while locked must not leave the shared simulator locked for the tests after it.
        addTeardownBlock { @MainActor in
            if let state = try? LockState() { Self.unlock(state) }
        }
        try pressLockButton()
        XCTAssertTrue(lockState.wait(locked: true, timeout: 10), "the screen did not lock")
        let behindLock = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter().wait(for: [behindLock], timeout: 10), .completed,
                       "the app stayed in front of the lock screen")
        UITestSupport.attachScreenshot("lock-screen", to: self)
        XCTAssertTrue(Self.unlock(lockState), "the screen did not unlock")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "unlocking did not return to the app")
        XCTAssertTrue(app.buttons["line.3.horizontal"].waitForExistence(timeout: 10),
                      "the play screen is gone: the app was relaunched")
        XCTAssertTrue(grid.exists)
        firstPad.tap()
        UITestSupport.attachScreenshot("after-unlock", to: self)
        app.buttons["line.3.horizontal"].tap()
        let quit = app.buttons["rectangle.portrait.and.arrow.right"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.tap()
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func chooseMode(_ mode: String, in app: XCUIApplication) {
        app.buttons["line.3.horizontal"].tap()
        let button = app.buttons[mode].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(mode) in the play menu")
        button.tap()
    }

    /// SpringBoard's published lock state, the one the system's own lock observers read.
    private final class LockState {
        private var token: Int32 = 0

        init() throws {
            let status = notify_register_check("com.apple.springboard.lockstate", &token)
            guard status == UInt32(NOTIFY_STATUS_OK) else {
                throw NSError(domain: "notify", code: Int(status))
            }
        }

        deinit { notify_cancel(token) }

        func wait(locked: Bool, timeout: TimeInterval) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            repeat {
                var state: UInt64 = 0
                if notify_get_state(token, &state) == UInt32(NOTIFY_STATUS_OK), (state != 0) == locked { return true }
                Thread.sleep(forTimeInterval: 0.2)
            } while Date() < deadline
            return false
        }
    }

    /// The simulator has no passcode: Home wakes the screen and a second Home unlocks it.
    /// Home is pressed only while the screen is still locked, so it never sends the app away.
    @MainActor @discardableResult
    private static func unlock(_ lockState: LockState) -> Bool {
        for _ in 0..<3 {
            if lockState.wait(locked: false, timeout: 0) { return true }
            XCUIDevice.shared.press(.home)
            if lockState.wait(locked: false, timeout: 3) { return true }
        }
        return false
    }

    /// XCUIDevice has no public lock button; its private one is what Simulator's Lock uses.
    private func pressLockButton() throws {
        let selector = NSSelectorFromString("pressLockButton")
        let device = XCUIDevice.shared
        try XCTUnwrap(device.responds(to: selector) ? device : nil,
                      "XCUIDevice no longer has pressLockButton").perform(selector)
    }
}
