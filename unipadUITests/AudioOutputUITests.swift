import Darwin
import XCTest

/// Opt-in: the host records only this simulator's UniPad process. The UI test
/// supplies real pad input; it never plays a reference in a separate player.
final class AudioOutputUITests: XCTestCase {
    private struct Scenario: Decodable {
        let name: String
        let columns: [Int]
        let hold: Double
    }

    @MainActor
    func testExternalOutput() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["UNIPAD_AUDIO_OUTPUT_DIR"],
              let token = environment["UNIPAD_AUDIO_OUTPUT_TOKEN"] else {
            throw XCTSkip("Run ci/audio_output_check.py with a managed recorder")
        }
        XCTAssertNotNil(UUID(uuidString: token))
        let directory = URL(fileURLWithPath: path)
        let scenarios = try JSONDecoder().decode([Scenario].self,
            from: Data(contentsOf: directory.appendingPathComponent("cases.json")))
        let app = XCUIApplication()
        app.launchArguments = ["-UniPadFirebaseLocalOnly", "YES", "-UniPadReleaseTest", token,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        defer { app.terminate() }
        let title = app.staticTexts["Audio Output Fixture"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "waiting for the isolated reference pack")
        title.tap()
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 3) { play.tap() }
        let grid = app.otherElements["playPadGrid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["line.3.horizontal"].waitForExistence(timeout: 30), "waiting for audio loading")
        UITestSupport.attachScreenshot("audio-output-reference-grid", to: self)

        for scenario in scenarios {
            let step = directory.appendingPathComponent(scenario.name)
            try Data("request".utf8).write(to: step.appendingPathComponent("request"), options: .atomic)
            // The host selects the process and hashes the installed app first.
            // Starting both deadlines at request could terminate the app while
            // the recorder is still resolving that process's sound object.
            _ = try waitForFile(step.appendingPathComponent("target-ready"), in: directory)
            let notice = try waitForFile(step.appendingPathComponent("ready.json"), in: directory)
            let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: notice) as? [String: Any])
            XCTAssertEqual(ready["ready"] as? Bool, true)
            XCTAssertEqual(ready["clock"] as? String, "CLOCK_UPTIME_RAW")
            XCTAssertNotNil(ready["first_frame_monotonic_ns"] as? NSNumber)
            // The host's notice follows the first received packet and initial-buffer discard.
            // Do not spend this quiet baseline in an app gesture or screenshot operation.
            Thread.sleep(forTimeInterval: 0.5)
            let invoked = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for column in scenario.columns {
                let pad = grid.coordinate(withNormalizedOffset:
                    CGVector(dx: (Double(column) - 0.5) / 8, dy: 0.5 / 8))
                if scenario.hold > 0 { pad.press(forDuration: scenario.hold) }
                else { pad.tap() }
            }
            let completed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let input: [String: Any] = ["invoked_ns": invoked, "completed_ns": completed]
            try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                .write(to: step.appendingPathComponent("input.json"), options: .atomic)
            _ = try waitForFile(step.appendingPathComponent("done.json"), in: directory)
        }
    }

    private func waitForFile(_ file: URL, in directory: URL) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("abort").path) {
                throw NSError(domain: "AudioOutputCheck", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "the host could not verify the recording environment"])
            }
            if FileManager.default.fileExists(atPath: file.path) { return try Data(contentsOf: file) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(domain: "AudioOutputCheck", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(file.lastPathComponent)"])
    }
}
