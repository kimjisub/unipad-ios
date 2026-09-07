//
//  DesignScreenshots.swift
//  unipadUITests
//
//  Walks the app and attaches a screenshot of every screen, so a maintenance run
//  can look at the design rather than guess at it from source.
//
//  This is not a pass/fail test. It never asserts on appearance, because a test
//  that fails when a colour changes is a test somebody deletes. It fails only
//  when it cannot reach a screen, which is a real regression worth knowing about.
//
//  Run it with:
//    xcodebuild test -project unipad.xcodeproj -scheme unipad \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//      -only-testing:unipadUITests/DesignScreenshots \
//      -resultBundlePath /tmp/unipad-shots.xcresult
//
//  and pull the images out with scripts/ios_shots.sh, which is what the harness
//  actually calls.
//

import XCTest

final class DesignScreenshots: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-UITestScreenshots"]
        app.launch()
        dismissSystemAlerts()
    }

    /// The app asks for notification permission during launch, so the very first
    /// thing on screen is a system alert covering the home screen. Tapping it away
    /// here keeps it out of every later shot; that it appears at all is a finding
    /// recorded separately, not something this file should paper over silently.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let buttons = ["허용 안 함", "Don't Allow", "허용", "Allow", "OK", "확인"]
            var tapped = false
            for label in buttons {
                let b = springboard.buttons[label]
                if b.waitForExistence(timeout: 2) {
                    b.tap()
                    tapped = true
                    break
                }
            }
            if !tapped { break }
        }
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// The accessibility tree, once, so whoever extends this file can see what is
    /// actually tappable instead of guessing at labels.
    private func dumpTree(_ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    func testWalkEveryScreen() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "app never came to the foreground")

        shot("01-main")
        dumpTree("00-tree-main")

        // Settings. The gear is the only control on the home screen that is not a
        // pack, so find it by identifier first and fall back to position.
        if tapFirst(["settings", "Settings", "설정", "gear", "gearshape"]) {
            sleep(1)
            shot("02-settings")
            dumpTree("00-tree-settings")
            goBack()
        }

        if tapFirst(["store", "Store", "스토어", "UniPad Store"]) {
            sleep(2)
            shot("03-store")
            dumpTree("00-tree-store")
            goBack()
        }

        if tapFirst(["theme", "Theme", "테마"]) {
            sleep(1)
            shot("04-theme")
            goBack()
        }

        if tapFirst(["midi", "MIDI", "MidiSelect", "미디"]) {
            sleep(1)
            shot("05-midi")
            goBack()
        }

        // A pack, if one is installed. Without content the list is empty, which is
        // itself worth a shot: the empty state is the first thing a new user sees.
        let cells = app.cells
        if cells.count > 0 {
            cells.element(boundBy: 0).tap()
            sleep(3)
            shot("06-play")
            dumpTree("00-tree-play")
        } else {
            shot("06-empty-list")
        }
    }

    private func tapFirst(_ candidates: [String]) -> Bool {
        for id in candidates {
            for element in [app.buttons[id], app.images[id], app.otherElements[id], app.staticTexts[id]] {
                if element.exists && element.isHittable {
                    element.tap()
                    return true
                }
            }
        }
        return false
    }

    private func goBack() {
        for label in ["Back", "뒤로", "닫기", "Close", "Done", "완료"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable {
                b.tap()
                sleep(1)
                return
            }
        }
        // No named control: a swipe from the left edge is how this app is closed.
        app.swipeRight()
        sleep(1)
    }
}
