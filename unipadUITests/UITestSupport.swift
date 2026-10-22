//
//  UITestSupport.swift
//  unipadUITests
//

import XCTest

enum UITestSupport {

    static var isReleaseSuite: Bool { ProcessInfo.processInfo.environment["UNIPAD_RELEASE_SUITE"] == "1" }

    /// Launch arguments for tests that find controls by their English text
    /// ("Information", "Theme", "Play", option names). The app follows the
    /// simulator's language, so these pin it to English to make the result the
    /// same whatever language the simulator was left in.
    static func englishLaunchArguments(library: String = "standard", token: String = UUID().uuidString,
                                       file: Bool = false, archive: Data? = nil,
                                       isolated: Bool? = nil, themeLoading: Bool = false) -> [String] {
        launchArguments(language: "en", locale: "en_US", library: library, token: token, file: file,
                        archive: archive, isolated: isolated, themeLoading: themeLoading)
    }

    /// Every launch argument a test passes to the app, each key once. An isolated launch
    /// prepares its own library under `token` (see ReleaseTestSupport). The whole suite always
    /// runs isolated; outside it, a launch is isolated when it asks for a particular library, a
    /// prepared file or an archive, so those requests are never dropped onto the real library.
    static func launchArguments(language: String, locale: String, library: String = "standard",
                                token: String = UUID().uuidString, file: Bool = false,
                                archive: Data? = nil, isolated: Bool? = nil,
                                themeLoading: Bool = false) -> [String] {
        let isolated = isolated ?? (isReleaseSuite || library != "standard" || file || archive != nil)
        var arguments = [
            "-UniPadFirebaseLocalOnly", "YES",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", locale,
        ]
        if isolated {
            arguments += ["-UniPadReleaseTest", token, "-UniPadUITestLibrary", library,
                          "-UniPadReleaseEmpty", library == "empty" ? "YES" : "NO",
                          "-UniPadReleaseFile", file ? "YES" : "NO"]
            if themeLoading { arguments += ["-UniPadReleaseThemeLoading", "YES"] }
            if let archive { arguments += ["-UniPadReleaseArchive", archive.base64EncodedString()] }
        }
        return arguments
    }

    /// For checks that need known packs whatever the simulator holds: the app gets a library of
    /// its own for this launch, filled with the fixture packs ReleaseTestSupport generates, and a
    /// store that answers from fixtures. The simulator's own packs are neither used nor changed.
    static func isolatedLibraryLaunchArguments(language: String = "en", locale: String = "en_US",
                                               library: String = "standard") -> [String] {
        launchArguments(language: language, locale: locale, library: library, isolated: true)
    }

    /// Creates a recent-play record through the same controls the user uses.
    static func playAndReturn(_ title: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(title.waitForExistence(timeout: 30), "the test pack must be prepared")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 30))
        app.buttons["line.3.horizontal"].tap()
        let quit = app.buttons["rectangle.portrait.and.arrow.right"]
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        // Close the selected-pack panel so its total and recent packs are visible.
        title.tap()
        XCTAssertTrue(app.staticTexts["main.total.playCount"].waitForExistence(timeout: 5))
    }

    /// Select the archive generated for this launch, through the system file picker.
    /// Browsing avoids relying on Spotlight to have indexed a freshly created file.
    static func selectPreparedArchive(token: String, in app: XCUIApplication) throws {
        _ = try XCTUnwrap(settledFilePickerCancelButton(in: app, timeout: 20))
        func tapRow(_ names: [String]) {
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label IN %@", names)).firstMatch
            let found = row.waitForExistence(timeout: 10)
            if !found { attachPickerDiagnostics(in: app, details: "missing row: \(names)") }
            XCTAssertTrue(found, "missing file picker row: \(names)")
            let window = app.windows.firstMatch.frame
            let viewport = window.insetBy(dx: 0, dy: 24)
            let deadline = Date().addingTimeInterval(20)
            while row.exists && !viewport.contains(row.frame) && Date() < deadline {
                // Locations may restore its scroll offset after a previous import.
                // isHittable also accepts a row clipped by the home indicator.
                // Application swipe directions can stay portrait-relative after
                // the picker rotates. Use vertical points in its current viewport.
                let distance = min(viewport.height * 0.5,
                                   max(100, abs(row.frame.midY - viewport.midY)))
                let high = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: viewport.midX, dy: viewport.midY - distance / 2))
                let low = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: viewport.midX, dy: viewport.midY + distance / 2))
                if row.frame.midY > viewport.midY {
                    low.press(forDuration: 0.1, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 0.2)
                } else {
                    high.press(forDuration: 0.1, thenDragTo: low, withVelocity: .slow, thenHoldForDuration: 0.2)
                }
            }
            let settled = waitForSettledFrame(timeout: 10,
                waitForArrival: { row.waitForExistence(timeout: $0) },
                frame: {
                    guard row.exists else { return nil }
                    // Each frame read requests another accessibility snapshot.
                    // Reuse this sample for visibility and stability so a slow
                    // picker does not spend the bounded wait reading it twice.
                    let current = row.frame
                    return viewport.contains(current) ? current : nil
                })
            if !settled { attachPickerDiagnostics(in: app, details: "row \(row.frame), viewport \(viewport)") }
            XCTAssertTrue(settled, "the file picker row must be fully visible and stable")
            XCTAssertTrue(waitUntilHittable(row, timeout: 5))
            row.tap()
        }
        let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "둘러보기", "Durchsuchen"])).firstMatch
        if browse.exists { browse.tap() }
        let localNames = ["On My iPhone", "나의 iPhone", "Auf meinem iPhone",
                          "On My iPad", "나의 iPad", "Auf meinem iPad"]
        let localStorage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", localNames)).firstMatch
        // On iOS 27 Browse restores its last folder after switching from Recents.
        // Return through its navigation history to Locations before choosing the path.
        for _ in 0..<4 {
            if localStorage.waitForExistence(timeout: 2) { break }
            let back = app.buttons["DOC.navBarButton.backInHistory"]
            guard back.exists && back.isEnabled else { break }
            XCTAssertTrue(waitUntilHittable(back, timeout: 5))
            back.tap()
        }
        tapRow(localNames)
        tapRow(["UniPad", "unipad"])
        // Grid folder titles can accept a synthetic tap without opening the folder.
        // Select its fully visible thumbnail once, by its on-screen point.
        let fixtureFolder = app.cells.containing(.staticText, identifier: "00-ReleaseTestImports").firstMatch
        let folderIcon = fixtureFolder.images.firstMatch
        let folderViewport = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 24)
        XCTAssertTrue(waitForSettledFrame(timeout: 10,
            waitForArrival: { folderIcon.waitForExistence(timeout: $0) },
            frame: {
                guard folderIcon.exists else { return nil }
                let current = folderIcon.frame
                return folderViewport.contains(current) ? current : nil
            }), "the isolated picker folder icon must be fully visible and stable")
        XCTAssertTrue(waitUntilHittable(folderIcon, timeout: 5))
        tapOnScreen(folderIcon, in: app)
        let cell = app.cells.containing(.staticText, identifier: "ReleaseFixture-\(token).zip").firstMatch
        let icon = cell.images.firstMatch
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        let tabs = app.tabBars.firstMatch
        // A folder can keep its search field and file grid while iOS hides the
        // floating tabs. Reserve their entire 64-point bottom area in either
        // layout, so a late tab bar cannot cover the icon or the drag path.
        // Any visible tabs must still fit on screen and stay below the search.
        var viewport = CGRect.null
        let controlsSettled = waitForSettledFrame(timeout: 20,
            waitForArrival: { search.waitForExistence(timeout: $0) },
            frame: {
                let screen = app.windows.firstMatch.frame
                guard search.exists, screen.contains(search.frame) else { return nil }
                var bottom = screen.maxY - 68
                if tabs.exists {
                    guard screen.contains(tabs.frame), tabs.frame.minY > search.frame.maxY + 8 else { return nil }
                    bottom = min(bottom, tabs.frame.minY - 4)
                }
                guard bottom > search.frame.maxY + 4 else { return nil }
                viewport = CGRect(x: screen.minX, y: search.frame.maxY + 4, width: screen.width,
                                  height: bottom - search.frame.maxY - 4)
                return viewport
            })
        if !controlsSettled {
            attachPickerDiagnostics(in: app, details: "folder controls: search exists \(search.exists), tabs exist \(tabs.exists)")
        }
        XCTAssertTrue(controlsSettled, "the unobscured file area must be visible and stable")
        func visible() -> Bool { icon.exists && viewport.contains(icon.frame) && icon.isHittable }
        let deadline = Date().addingTimeInterval(60)
        while !visible() && Date() < deadline {
            // The collection view also extends underneath the search bar and tabs.
            // Drag inside the unobscured viewport, towards its centre, rather than
            // using a fixed fraction of the covered collection view.
            let frame = icon.exists ? icon.frame : CGRect.null
            let moveDown = !frame.isNull && frame.midY < viewport.midY
            let distance = frame.isNull ? viewport.height * 0.65 :
                min(viewport.height * 0.65, max(16, abs(frame.midY - viewport.midY)))
            let x = viewport.minX + viewport.width * 0.8
            let high = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x, dy: viewport.midY - distance / 2))
            let low = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x, dy: viewport.midY + distance / 2))
            if moveDown {
                high.press(forDuration: 0.1, thenDragTo: low, withVelocity: .slow, thenHoldForDuration: 0.2)
            } else {
                low.press(forDuration: 0.1, thenDragTo: high, withVelocity: .slow, thenHoldForDuration: 0.2)
            }
        }
        if !visible() {
            attachPickerDiagnostics(in: app, details: "archive \(icon.frame), viewport \(viewport)")
        }
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertTrue(visible(), "the archive icon must be visible before selecting it")
        XCTContext.runActivity(named: "Select the fully visible prepared archive") { activity in
            let state = XCTAttachment(string: "tabs present: \(tabs.exists), icon: \(icon.frame), viewport: \(viewport)\n" + app.debugDescription)
            state.name = "prepared-archive-selection"
            activity.add(state)
            activity.add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        }
        icon.tap()
        // A busy picker can drop a tap on a settled, hittable icon and stay open with
        // nothing chosen. Choosing the file closes the picker, so tap the icon's screen
        // point again only while the picker still shows it where a tap reaches it.
        for _ in 0..<2 {
            guard !cell.waitForNonExistence(timeout: 10), visible() else { return }
            attachPickerDiagnostics(in: app, details: "the archive tap left the picker open")
            tapOnScreen(icon, in: app)
        }
    }

    /// Clears system alerts left over the app when a test starts. The app itself
    /// asks for notification permission only when a store download starts, never
    /// at launch, so on a fresh install there is normally nothing to clear here.
    static func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["허용 안 함", "Don't Allow", "허용", "Allow", "OK", "확인"]
        for _ in 0..<3 {
            guard springboard.alerts.firstMatch.waitForExistence(timeout: 1) else { return }
            // An alert that is still sliding in lists its buttons before they take taps.
            let anyButton = springboard.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            guard anyButton.waitForExistence(timeout: 2),
                  let button = labels.lazy.map({ springboard.buttons[$0] }).first(where: { $0.exists }),
                  waitUntilHittable(button, timeout: 2) else { return }
            button.tap()
        }
    }

    /// The back chevron every pushed screen draws for itself (the navigation bar is hidden).
    static func backButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["chevron.left"].firstMatch
    }

    /// Taps the middle of the part of `element` that is on screen, the way a finger would.
    ///
    /// On a screen with no side safe area (iPhone SE in landscape) Settings' back
    /// button starts at x = -4 because its 44pt tap area reaches past the glyph.
    /// On iOS 27 `XCUIElement.tap()` on that button never reaches the app, while
    /// touches anywhere inside it (x = 2 to 46) go back home, so the tap is sent to
    /// a screen point instead.
    static func tapOnScreen(_ element: XCUIElement, in app: XCUIApplication) {
        let visible = element.frame.intersection(app.windows.firstMatch.frame)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visible.midX, dy: visible.midY))
            .tap()
    }

    static func tapBack(in app: XCUIApplication) {
        tapOnScreen(backButton(in: app), in: app)
    }

    /// Waits until `element` is on screen where a tap would reach it. An element
    /// is listed while a system sheet still covers it or while its screen is
    /// still settling; tapping it then makes XCUITest scroll to it first and the
    /// tap goes nowhere.
    static func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }

    /// The system file picker's cancel button, once the picker has settled.
    ///
    /// The picker runs in its own process and, on an iPhone, lays itself out several times as it
    /// opens: as a sheet, as a split view whose sidebar has a cancel button of its
    /// own, and with a phone-width bar, before it fills the screen. Its cancel
    /// button is listed at each of those places in turn, and XCUITest waits only
    /// for the app to go idle, not the picker, so a tap aimed at an earlier layout
    /// lands on empty space once the picker has moved on, and the picker stays
    /// open. The button is returned only once it sits in the full-width bar the
    /// picker ends in and has stopped moving. Its label is in the app's language.
    ///
    /// On an iPad the picker ends as a sheet in the middle of the screen with its
    /// sidebar shown, and the cancel button, drawn as an X, stays in the sidebar's bar.
    static func settledFilePickerCancelButton(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let onPad = UIDevice.current.userInterfaceIdiom == .pad
        let bar = app.navigationBars[onPad ? "DOCSidebarView" : "FullDocumentManagerViewControllerNavigationBar"]
        let cancel = bar.buttons
            .matching(NSPredicate(format: "label IN %@", ["Cancel", "취소", "Cancelar", "Abbrechen"]))
            .firstMatch
        let screenWidth = app.windows.firstMatch.frame.width
        let didSettle = waitForSettledFrame(timeout: timeout,
            waitForArrival: { cancel.waitForExistence(timeout: $0) },
            frame: {
                guard cancel.exists, onPad || bar.frame.width == screenWidth else { return nil }
                return cancel.frame
            })
        guard didSettle else {
            attachPickerDiagnostics(in: app, details:
                "initial window width \(screenWidth), window \(app.windows.firstMatch.frame), " +
                "navigation \(bar.exists ? bar.frame : .null), cancel exists \(cancel.exists)")
            return nil
        }
        return cancel
    }

    /// Requires two consecutive samples of the same final control frame.
    static func waitForSettledFrame(timeout: TimeInterval,
                                    waitForArrival: (TimeInterval) -> Bool,
                                    frame: @escaping () -> CGRect?) -> Bool {
        // Accessibility discovery can finish near its deadline on a hosted runner.
        // Give the two stable-frame samples their own bounded wait after arrival.
        guard waitForArrival(timeout) else { return false }
        var lastFrame = CGRect.null
        let settled = NSPredicate { _, _ in
            guard let current = frame() else {

                lastFrame = .null
                return false
            }
            defer { lastFrame = current }
            return current == lastFrame
        }
        let expectation = XCTNSPredicateExpectation(predicate: settled, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private static func attachPickerDiagnostics(in app: XCUIApplication, details: String) {
        XCTContext.runActivity(named: "File picker did not settle: " + details) { activity in
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
            let tree = XCTAttachment(string: details + "\n" + app.debugDescription)
            tree.name = "file-picker-state"
            tree.lifetime = .keepAlways
            activity.add(tree)
        }
    }

    /// XCUITest can report offscreen rows as hittable in landscapeRight. Use
    /// the window and scroll viewport instead, and require the whole row so
    /// its activation point cannot still sit below the fold.
    static func isFullyVisible(_ element: XCUIElement, in app: XCUIApplication,
                               within scrollView: XCUIElement? = nil) -> Bool {
        guard element.exists else { return false }
        var viewport = app.windows.firstMatch.frame
        if let scrollView {
            guard scrollView.exists else { return false }
            viewport = viewport.intersection(scrollView.frame)
        }
        let frame = element.frame
        return !viewport.isEmpty && !frame.isEmpty && viewport.contains(frame)
    }

    /// Search exposes a fixture even when a large lazy library has not created its row yet.
    static func searchForPack(_ query: String, in app: XCUIApplication) {
        let toggle = app.buttons["magnifyingglass"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(query)
        field.typeText("\n")
    }

    @discardableResult
    static func scrollIntoView(_ element: XCUIElement, in scrollView: XCUIElement,
                               app: XCUIApplication, maxSwipes: Int = 6) -> Bool {
        for _ in 0..<maxSwipes {
            if isFullyVisible(element, in: app, within: scrollView) { return true }
            guard scrollView.exists, element.exists else { return false }
            let viewport = scrollView.frame.intersection(app.windows.firstMatch.frame)
            guard !viewport.isEmpty else { return false }
            if let shift = nearbyShift(of: element.frame, into: viewport) {
                drag(scrollView, by: shift, within: viewport)
            } else if element.frame.midY < viewport.midY {
                scrollView.swipeDown(velocity: .slow)
            } else {
                scrollView.swipeUp(velocity: .slow)
            }
        }
        return isFullyVisible(element, in: app, within: scrollView)
    }

    /// How far the content must move up (negative: down) to bring a partly hidden element fully
    /// into `viewport`, or nil when it is too far away for one short drag. A swipe moves a list
    /// by about a screen, so an element just past the edge jumps to the other side of the middle
    /// and the next swipe throws it back past the same edge.
    private static func nearbyShift(of frame: CGRect, into viewport: CGRect) -> CGFloat? {
        let margin: CGFloat = 16
        let shift: CGFloat
        if frame.maxY > viewport.maxY {
            shift = frame.maxY - viewport.maxY + margin
        } else if frame.minY < viewport.minY {
            shift = frame.minY - viewport.minY - margin
        } else {
            return nil
        }
        return abs(shift) <= viewport.height * 0.6 ? shift : nil
    }

    /// Drags the content of `scrollView` up by `distance` points and holds before lifting the
    /// finger, so the list stops where it was dragged instead of coasting on.
    private static func drag(_ scrollView: XCUIElement, by distance: CGFloat, within viewport: CGRect) {
        // The list only starts to follow the finger after it has moved a few points.
        let touchSlop: CGFloat = 12
        let travel = distance + (distance > 0 ? touchSlop : -touchSlop)
        let origin = scrollView.coordinate(withNormalizedOffset: .zero)
        let x = viewport.midX - scrollView.frame.minX
        let start = origin.withOffset(CGVector(dx: x, dy: viewport.midY - scrollView.frame.minY + travel / 2))
        let end = origin.withOffset(CGVector(dx: x, dy: viewport.midY - scrollView.frame.minY - travel / 2))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// The home screen's download and import cards. They sit in the middle of an
    /// empty list and after the last pack of a full one, so a long list has to be
    /// scrolled before the card can be tapped. Packs load after home appears, so
    /// this keeps scrolling until the deadline rather than for a fixed count.
    enum HomeCard: String {
        case download = "main.guide.download"
        case `import` = "main.guide.import"
    }

    static func revealHomeCard(_ card: HomeCard, in app: XCUIApplication, timeout: TimeInterval = 60) -> XCUIElement {
        let element = app.buttons[card.rawValue].firstMatch
        // A short empty-library screen scrolls too, but has no pack-list ID.
        // Choose the card's enclosing scroll view rather than the left panel's.
        let list = app.scrollViews["main.packList"]
        let cardScrollView = app.scrollViews.containing(.button, identifier: card.rawValue).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Lazy stacks do not expose the card until the list is scrolled.
            let scrollView = list.exists ? list : cardScrollView
            let viewport = scrollView.exists ? scrollView : nil
            if isFullyVisible(element, in: app, within: viewport) { break }
            if let viewport {
                if element.exists {
                    _ = scrollIntoView(element, in: viewport, app: app, maxSwipes: 1)
                } else {
                    viewport.swipeUp(velocity: .slow)
                }
            } else {
                _ = element.waitForExistence(timeout: 1)
            }
        }
        return element
    }

    /// Opens the store from the home card and waits until its list has rows.
    static func openStore(in app: XCUIApplication, testCase: XCTestCase) -> XCUIElement {
        let back = backButton(in: app)
        for _ in 0..<3 where !back.exists {
            revealHomeCard(.download, in: app).tap()
            _ = back.waitForExistence(timeout: 5)
        }
        let list = app.scrollViews["store.list"]
        if !list.waitForExistence(timeout: 30) {
            attachScreenshot("store-not-loaded", to: testCase)
            XCTFail(back.exists ? "store list never loaded (no network on the simulator?)" : "download card did not open the store")
        }
        XCTAssertTrue(storeRows(in: list).firstMatch.waitForExistence(timeout: 15), "store list has no rows")
        return list
    }

    static func storeRows(in list: XCUIElement) -> XCUIElementQuery {
        list.descendants(matching: .any).matching(identifier: "store.row")
    }

    /// Sets a play option switch in the open option panel. The row is one combined
    /// accessibility element labelled with the option's name.
    /// The option panel scrolls on a landscape iPhone, so the switch is first brought into view.
    /// Each row carries a long-press gesture over its whole width, so only the toggle at the
    /// trailing edge flips the value.
    static func setPlayOption(_ label: String, on: Bool, in app: XCUIApplication) {
        let row = app.switches[label].firstMatch
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("no \(label) option in the menu")
            return
        }
        let panel = app.scrollViews.firstMatch
        let inView = { panel.frame.contains(row.frame) }
        for _ in 0..<6 where !inView() {
            if row.frame.midY < panel.frame.midY { panel.swipeDown(velocity: .slow) } else { panel.swipeUp(velocity: .slow) }
        }
        guard inView() else {
            XCTFail("\(label) option never scrolled into view")
            return
        }

        let isOn: () -> Bool = { (row.value as? String) == "1" }
        guard isOn() != on else { return }
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(isOn(), on, "\(label) option did not switch")
    }

    /// Opens the Playback Stop fixture's play screen from home. Launch with
    /// `isolatedLibraryLaunchArguments`, whose library has the fixture; a missing fixture fails the check.
    static func openPlaybackStopFixture(in app: XCUIApplication, playButtonTitle: String = "Play") {
        openPack(titled: "Playback Stop Fixture", in: app, playButtonTitle: playButtonTitle,
                 missingMessage: "the Playback Stop fixture was not prepared")
    }

    /// Opens the play screen of the pack whose title contains `packTitle` from home.
    static func openPack(titled packTitle: String, in app: XCUIApplication, playButtonTitle: String = "Play",
                         missingMessage: String) {
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 15))
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", packTitle)).firstMatch
        // A long lazy list may not have created the pack's row yet.
        if !title.exists { searchForPack(packTitle, in: app) }
        XCTAssertTrue(title.waitForExistence(timeout: 10), missingMessage)
        title.tap()
        let play = app.buttons[playButtonTitle].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() } else { title.tap() }
        XCTAssertTrue(app.otherElements["playPadGrid"].waitForExistence(timeout: 15))
    }

    /// iPadOS draws a "hidden windows / show all windows" pill after an app comes to the front.
    /// It can remain until an app interaction dismisses it. Screenshots include it, so callers
    /// dismiss it before waiting. Returns false when it is still there after the timeout.
    static func waitForHiddenWindowsPillToGo(timeout: TimeInterval) -> Bool {
        let pill = XCUIApplication(bundleIdentifier: "com.apple.springboard").images["macwindow.on.rectangle"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pill)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    static func attachScreenshot(_ name: String, to testCase: XCTestCase) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        testCase.add(a)
    }
}
