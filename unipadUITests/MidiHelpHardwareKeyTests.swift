import XCTest
import CoreFoundation

/// Help checks that need a real hardware key press. On the iOS simulator
/// XCTest's typeKey never sends Escape (the app receives no key event at all),
/// so these tests ask the host to press it through the simulator's HID input
/// instead. Run them with `ci/host-keys.sh`; without it they are skipped.
///
/// The simulator sometimes accepts a host key press and hands it to no app.
/// The app is therefore launched with the host's key arrival probe, and every
/// Escape is checked against it: a press that never reached the app is pressed
/// again (at most three presses, all attached to the result), and one that did
/// reach it must close the help as before.
final class MidiHelpHardwareKeyTests: XCTestCase {
    private static let escape = "key 41"
    private static let escapeArrival = "began 41"
    private static let escapePresses = 3
    private var app: XCUIApplication!
    private var arrivalLog: String!
    private var navigationNotification: String!

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

    override class func setUp() {
        super.setUp()
        #if compiler(>=6.4)
        if hostKeysDirectory != nil {
            XCTAssertNoThrow(try disableVoiceOverIfEnabled())
        }
        #endif
    }

    override class func tearDown() {
        #if compiler(>=6.4)
        if hostKeysDirectory != nil {
            XCTAssertNoThrow(try disableVoiceOverIfEnabled())
        }
        #endif
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard Self.hostKeysDirectory != nil else {
            throw XCTSkip("Needs a real key press from the host: run ci/host-keys.sh")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDownWithError() throws {
        #if compiler(>=6.4)
        // Successful repetitions share the suite's session. A failed test
        // still cleans up immediately, including an uncaught automation error.
        if (testRun?.totalFailureCount ?? 0) > 0 {
            try Self.disableVoiceOverIfEnabled()
        }
        #endif
    }

    #if compiler(>=6.4)
    private static func disableVoiceOverIfEnabled() throws {
        if #available(iOS 27.0, *), XCUIDevice.shared.voiceOverService.isEnabled {
            try XCUIDevice.shared.voiceOverService.disable()
        }
    }
    #endif

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
        let response = try? String(contentsOfFile: "\(dir)/done-\(id)", encoding: .utf8)
        let output = (try? String(contentsOfFile: "\(dir)/output-\(id)", encoding: .utf8)) ?? ""
        let delivery = XCTAttachment(string: "request=\(keys)\nresponse=\(response ?? "missing")\n\(output)")
        delivery.name = "host-key-delivery-\(id)"
        delivery.lifetime = .keepAlways
        add(delivery)
        XCTAssertEqual(response?.trimmingCharacters(in: .whitespacesAndNewlines), "successful",
                       "The host must deliver the key successfully: \(output)")
    }

    private var arrivals: String {
        (try? String(contentsOfFile: arrivalLog, encoding: .utf8)) ?? ""
    }

    private func escapesArrived() -> Int {
        arrivals.split(separator: "\n").filter { $0 == Self.escapeArrival }.count
    }

    /// Presses Escape on the host until the app's event entry has received it.
    /// Only a press the app provably never received is repeated; what the app
    /// does with a received one is left to the caller's checks.
    private func pressEscape(_ step: String) {
        var record: [String] = []
        var arrived = false
        for press in 1...Self.escapePresses where !arrived {
            let before = escapesArrived()
            pressHostKeys(Self.escape)
            let received = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
                self.escapesArrived() > before
            }, object: nil)
            arrived = XCTWaiter().wait(for: [received], timeout: 3) == .completed
            record.append("press \(press): " + (arrived ? "reached the app" : "did not reach the app within 3 s"))
        }
        let attachment = XCTAttachment(string: record.joined(separator: "\n") + "\n\nkey arrival log:\n" + arrivals)
        attachment.name = "escape-delivery-\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("Escape delivery (\(step)): \(record.joined(separator: "; "))")
        XCTAssertTrue(arrived, "Test input failure, not an app result: the host pressed Escape "
                      + "\(Self.escapePresses) times and none reached the app")
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
        let dir = Self.hostKeysDirectory!
        arrivalLog = "\(dir)/arrivals-\(UUID().uuidString)"
        app.launchEnvironment["DYLD_INSERT_LIBRARIES"] = "\(dir)/key-arrival-probe.dylib"
        app.launchEnvironment["UNIPAD_KEY_ARRIVAL_LOG"] = arrivalLog
        navigationNotification = "unipad.ui-tests.navigation.\(UUID().uuidString)"
        app.launchEnvironment["UNIPAD_VOICEOVER_NAVIGATION"] = navigationNotification
        app.launch()
        XCTAssertTrue(FileManager.default.fileExists(atPath: arrivalLog),
                      "the key arrival probe did not load into the app")
        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 30))
        activate(app.buttons["gearshape"])
        XCTAssertTrue(app.buttons[labels.reconnect].waitForExistence(timeout: 10))
        activate(app.buttons[labels.reconnect])
        activate(app.buttons["midi.help.open"])
        XCTAssertTrue(app.buttons["midi.help.close"].waitForExistence(timeout: 5))
        return labels
    }

    private func activate(_ button: XCUIElement) {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *), XCUIDevice.shared.voiceOverService.isEnabled {
            // Simulator VoiceOver taps select instead of activating. A local
            // notification asks the test-only probe to invoke this setup button's
            // public accessibility action once. Avoid a host input round trip:
            // MIDI selection automatically closes after five seconds.
            // The probe permits only setup buttons and leaves Escape untouched.
            let identifier = button.identifier
            let label = button.label
            let offset = arrivals.count
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["identifier": identifier, "label": label])
                .write(to: URL(fileURLWithPath: arrivalLog + "-navigation.json"), options: .atomic))
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(rawValue: navigationNotification as CFString), nil, nil, true)
            let completed = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
                (String(self.arrivals.dropFirst(offset)).contains("navigation activated=1\n")
                    || String(self.arrivals.dropFirst(offset)).contains("navigation activated=0\n"))
            }, object: nil)
            let received = XCTWaiter().wait(for: [completed], timeout: 3) == .completed
            let record = String(arrivals.dropFirst(offset))
            let attachment = XCTAttachment(string: record)
            attachment.name = "voiceover-navigation-\(identifier)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertTrue(received, "Navigation action did not complete: \(record)")
            XCTAssertTrue(record.contains("navigation target \(identifier) | \(label) allowed=1"),
                          "The probe resolved a different navigation target: \(record)")
            XCTAssertTrue(record.contains("navigation activated=1"),
                          "The requested navigation button did not activate: \(record)")
            return
        }
        #endif
        button.tap()
    }

    private static let ignoredEscape = "Escape reached the app but the help did not close"

    /// The opener stays in XCTest's tree while the help hides it, so its
    /// presence proves nothing; wait for the help itself to go away.
    private func assertHelpClosed(_ step: String) {
        let closed = app.buttons["midi.help.close"].waitForNonExistence(timeout: 5)
        if !closed {
            UITestSupport.attachScreenshot("\(step)-still-open", to: self)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(step)-still-open-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(closed, Self.ignoredEscape)
        XCTAssertTrue(app.buttons["midi.help.open"].waitForExistence(timeout: 5), Self.ignoredEscape)
    }

    private func assertOnlyHelpClosed(_ labels: Labels) {
        assertHelpClosed("real-escape")
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
            pressEscape(language)
            assertOnlyHelpClosed(labels)
            UITestSupport.attachScreenshot("escape-after-\(language)", to: self)
            app.terminate()
        }
    }

    // VoiceOver automation is supplied by Xcode 27; older compilers lack it.
    #if compiler(>=6.4)
    @MainActor
    func testVoiceOverReadsHelpAndEscapeReturnsFocusInBothLanguages() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver automation requires iOS 27") }
        let voiceOver = XCUIDevice.shared.voiceOverService
        // Keep one automation connection across app launches. Disabling and
        // re-enabling in the same test runner can reuse a destroyed connection.
        for language in ["en", "ko"] {
            let labels = openHelp(language: language)
            if language == "en", !voiceOver.isEnabled { try voiceOver.enable() }
            try checkVoiceOver(language: language, labels: labels)
            app.terminate()
        }
    }

    /// VoiceOver reads the help's title, selected model and close button, never
    /// leaves the help while moving through it, and after a real Escape on the
    /// close button its focus is back on the button that opened the help.
    ///
    /// Leave focus on the close button and send a real Escape to check keyboard
    /// dismissal and the return of VoiceOver focus to the help button.
    @MainActor
    private func checkVoiceOver(language: String, labels: Labels) throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver automation requires iOS 27") }
        let voiceOver = XCUIDevice.shared.voiceOverService
        // Enabling speaks nothing of its own; any current speech is an unrelated
        // system announcement (e.g. "Port on right"), and without one reading it
        // throws "No speech available". Start reading by moving instead.
        // isEnabled does not report command readiness. Diagnose a failed first
        // delivery without retrying it or treating it as missing app content.
        var speech: String
        do {
            speech = try VoiceOverReading.firstSpeech { try voiceOver.moveForward().utterance }
        } catch let error as VoiceOverReading.AutomationNotReady {
            let diagnostic = XCTAttachment(string: "\(error.localizedDescription)\n"
                + "language=\(language)\nVoiceOver enabled=\(voiceOver.isEnabled)\n"
                + "\(voiceOver.debugDescription)\n\(app.debugDescription)")
            diagnostic.name = "voiceover-first-command-\(language)"
            diagnostic.lifetime = .keepAlways
            add(diagnostic)
            throw error
        }
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
        XCTAssertTrue(transcript.contains { $0.contains(labels.title) },
                      "App speech is missing the help title:\n\(text)")
        XCTAssertTrue(transcript.contains { $0.contains(labels.model) && $0.contains("Launchpad S") },
                      "App speech is missing the selected model:\n\(text)")
        XCTAssertTrue(transcript.contains { $0.contains(labels.close) },
                      "App speech is missing the close button:\n\(text)")
        UITestSupport.attachScreenshot("voiceover-help-\(language)", to: self)

        for _ in 0..<24 where !speech.contains(labels.close) {
            speech = try voiceOver.moveBackward().utterance
        }
        XCTAssertTrue(speech.contains(labels.close), "VoiceOver must be on the close button: \(speech)")
        pressEscape("voiceover-\(language)")
        assertHelpClosed("voiceover-escape-\(language)")
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
    }
    #endif
}
