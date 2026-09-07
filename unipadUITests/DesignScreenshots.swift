//
//  DesignScreenshots.swift
//  unipadUITests
//
//  Walks the app and attaches a screenshot of every screen, so a maintenance run
//  can look at the design rather than guess at it from source.
//
//  This is not a pass/fail test of appearance. It never asserts on how anything
//  looks, because a test that fails when a colour changes is a test somebody
//  deletes. It asserts that each screen was reached, which is a real regression
//  when it breaks, and it fails loudly rather than quietly attaching the previous
//  screen again. The first version of this file did exactly that: three of its
//  four "screenshots" were byte-identical copies of the home screen, and the
//  file count looked like coverage.
//
//  Run it with:
//    xcodebuild test -project unipad.xcodeproj -scheme unipad \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//      -only-testing:unipadUITests/DesignScreenshots \
//      -resultBundlePath /tmp/unipad-shots.xcresult
//
//  and pull the images out with unipad-maintain/scripts/ios_shots.sh, which is
//  what the harness actually calls.
//

import XCTest

final class DesignScreenshots: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        // Keep going after a failure: a screen that cannot be reached should not
        // cost every screen after it. The failures are still reported.
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        dismissSystemAlerts()
    }

    /// The app asks for notification permission during launch, so the first thing
    /// on screen is a system alert covering the home screen. Tapping it away keeps
    /// it out of every later shot. That it appears at all, before the user has
    /// seen anything, is a finding recorded separately rather than papered over.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            var tapped = false
            for label in ["허용 안 함", "Don't Allow", "허용", "Allow", "OK", "확인"] {
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

    /// The accessibility tree, so whoever extends this file can see what is
    /// actually on screen instead of guessing at labels. Every control below was
    /// found by reading one of these.
    private func dumpTree(_ name: String) {
        let a = XCTAttachment(string: app.debugDescription)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Wait for something that only exists on the screen we just navigated to.
    /// Without this the shot is taken mid-transition, or on the previous screen
    /// when the tap did nothing at all.
    @discardableResult
    private func arrive(_ marker: XCUIElement, _ screen: String) -> Bool {
        let ok = marker.waitForExistence(timeout: 10)
        XCTAssertTrue(ok, "never arrived at \(screen); read the attached tree for what was on screen")
        return ok
    }

    private func back() {
        let chevron = app.buttons["chevron.left"]
        if chevron.exists && chevron.isHittable {
            chevron.tap()
        } else {
            app.swipeRight()
        }
        _ = app.buttons["gearshape"].waitForExistence(timeout: 10)
    }

    @MainActor
    func testWalkEveryScreen() throws {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "app never came to the foreground")

        // Home. The gear is the marker for "we are on the home screen" everywhere
        // below, because it exists here and nowhere else.
        arrive(app.buttons["gearshape"], "home")
        shot("01-main")
        dumpTree("00-tree-main")

        // Settings, and Theme from inside it. Theme is not on the home screen;
        // looking for it there was why the first version silently re-shot home.
        app.buttons["gearshape"].tap()
        if arrive(app.buttons["Information"], "settings") {
            shot("02-settings")
            dumpTree("00-tree-settings")

            app.buttons["Theme"].tap()
            if arrive(app.staticTexts["Theme"].firstMatch, "theme") {
                shot("03-theme")
                dumpTree("00-tree-theme")
                back()
                _ = app.buttons["Information"].waitForExistence(timeout: 10)
            }
            back()
        }

        // Store, reached by the cart in the top bar.
        arrive(app.buttons["gearshape"], "home before store")
        app.buttons["cart"].firstMatch.tap()
        if arrive(app.buttons["chevron.left"], "store") {
            // The store loads over the network; give the list a moment so the shot
            // is of the store rather than of its spinner.
            _ = app.staticTexts.element(boundBy: 1).waitForExistence(timeout: 15)
            shot("04-store")
            dumpTree("00-tree-store")
            back()
        }

        // Play. The pack row is not a cell and not a button; it is an `Other`
        // holding the title as static text, so the title is what gets tapped.
        arrive(app.buttons["gearshape"], "home before play")
        let packTitles = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", " - "))
        if packTitles.count > 0 {
            let title = packTitles.element(boundBy: 0)
            title.tap()          // first tap selects and opens the detail panel
            sleep(1)
            shot("05-pack-selected")

            // Selecting reveals a Play control in the flag area.
            let play = app.buttons["Play"].firstMatch
            if play.waitForExistence(timeout: 5) {
                play.tap()
            } else {
                title.tap()      // second tap on the row opens it
            }
            sleep(3)
            shot("06-play")
            dumpTree("00-tree-play")
        } else {
            XCTFail("no pack in the list; ios_shots.sh installs one before the walk")
            shot("06-empty-list")
        }
    }
}
