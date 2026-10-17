import Foundation
import Testing
import XCTest
@testable import unipad

/// The intended timeline the real-time runs are compared with follows LedRunner's rules.
@MainActor
struct LedTimingTimelineTests {
    private func pack(buttons: Int = 8, chains: Int = 1, keyLed: [String: String], autoPlay: String) throws -> UniPack {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LedTimeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        return LedTimingPackFiles.load(try LedTimingPackFiles.write(to: root, buttons: buttons, keyLed: keyLed, autoPlay: autoPlay, chains: chains))
    }

    private func lines(_ timeline: IntendedLedTimeline) -> [String] {
        timeline.commands.map { "\(Int($0.ms)) \($0.target)=\($0.code)" }
    }

    @Test func followsLedRunnerOwnershipAndShutdownRules() throws {
        let timeline = IntendedLedTimeline.of(try pack(
            keyLed: [
                "1 1 1 1": "o 1 1 a 5\nd 10\no 2 2 a 7\nd 10\nf 1 1\nf 2 2\n",
                "1 2 1 0": "o 2 2 a 9\nd 100\n",
            ],
            autoPlay: "o 1 1\nd 5\no 2 1\nd 10\no 1 1\nd 100\nf 2 1\n"
        ))

        #expect(lines(timeline) == [
            "0 pad 0,0=5",
            "5 pad 1,1=9",
            // The first pad's animation takes (1,1) over, so its own off applies later and the endless one's does not.
            "10 pad 1,1=7",
            // Pressing the first pad again ends its animation and turns off everything it lit.
            "15 pad 0,0=0", "15 pad 1,1=0",
            "15 pad 0,0=5",
            "25 pad 1,1=7",
            "35 pad 0,0=0", "35 pad 1,1=0",
            "105 pad 1,1=9",
            // Releasing the second pad ends its endless animation.
            "115 pad 1,1=0",
        ])
    }

    /// The last pad's keyLED moves to chain 2, so the final release on that chain ends chain 2's endless animation.
    @Test func followsAKeyLedChainChange() throws {
        let timeline = IntendedLedTimeline.of(try pack(
            chains: 2,
            keyLed: ["2 2 2 0": "o 2 2 a 9\nd 50\n", "1 1 1 1": "o 1 1 a 5\nc 2\n"],
            autoPlay: "c 2\no 2 2\nd 10\nc 1\no 1 1\n"
        ), releaseAllAtMs: 120)

        #expect(lines(timeline) == ["0 pad 1,1=9", "10 pad 0,0=5", "50 pad 1,1=9", "100 pad 1,1=9", "120 pad 1,1=0"])
    }

    /// An endless animation the final release does not reach (another chain's) plays until the run gives up.
    @Test func stopsAnUnreleasedEndlessAnimationAtTheGiveUpTime() throws {
        let timeline = IntendedLedTimeline.of(try pack(
            chains: 2,
            keyLed: ["2 2 2 0": "o 2 2 a 9\nd 50\n"],
            autoPlay: "c 2\no 2 2\nd 10\nc 1\n"
        ), releaseAllAtMs: 20, giveUpAtMs: 120)

        #expect(timeline.commands.map(\.ms) == [0, 50, 100])
    }

    /// LedRunner keeps playing an endless animation without delays one pass a tick; it still owns its LED until released.
    @Test func releasesAnEndlessAnimationWithoutDelays() throws {
        let timeline = IntendedLedTimeline.of(try pack(
            keyLed: ["1 3 3 0": "o 3 3 a 7\nf 3 3\n"],
            autoPlay: "o 3 3\n"
        ), releaseAllAtMs: 30)

        #expect(lines(timeline) == ["0 pad 2,2=7", "0 pad 2,2=0", "0 pad 2,2=7", "30 pad 2,2=0"])
        #expect(timeline.delaylessEndlessAnimations == 1)
    }

    /// Round LEDs and the logo are addressed as LedRunner hands them over: x -1, the round index or 32.
    @Test func addressesRoundLedsAndTheLogo() throws {
        let timeline = IntendedLedTimeline.of(try pack(
            keyLed: ["1 1 1 1": "o mc 3 a 9\no l a 5\nd 10\nf mc 3\nf l\n"],
            autoPlay: "o 1 1\n"
        ))

        #expect(lines(timeline) == ["0 round 2=9", "0 round 32=5", "10 round 2=0", "10 round 32=0"])
    }
}

/// Whether the LED commands autoplay sends to the Launchpad keep the pack's order and leave none out,
/// on the real clock through the real LED path (LedPathRun). Latency is printed, not asserted: it
/// depends on the machine and its load. Store packs are measured by StorePackLedTimingTests.
///
/// XCTest rather than Swift Testing: XCTest runs one test at a time, and this one owns
/// MidiManager.shared's driver while it plays. With UNIPAD_LED_TIMING_MIDI set (see VirtualLaunchpad)
/// the commands also go out as MIDI to a virtual Launchpad MK2, which must receive all of them in order.
@MainActor
final class LedTimingTests: XCTestCase {
    func testKeyLedChainChangeDoesNotCountRepaintsAsRunnerCommands() async throws {
        let recording = try await record(
            keyLed: ["1 1 1 1": "o 1 1 a 5\nd 20\nc 2\nd 20\nf 1 1\n"],
            autoPlay: "o 1 1\n", releaseAll: 200, giveUp: 1000
        )
        XCTAssertEqual(recording.handedOver.count, 2)
        XCTAssertEqual(recording.toDriver.map(\.code), [5, 0])
        XCTAssertGreaterThanOrEqual(recording.repaints, 24)
        assertDelivered(recording)
    }

    func testUnreleasedAnimationIsNotRecordedAfterGiveUp() async throws {
        let recording = try await record(
            keyLed: ["2 2 2 0": "o 2 2 a 9\nd 50\n"],
            autoPlay: "c 2\no 2 2\nd 10\nc 1\n", releaseAll: 100, giveUp: 625
        )
        XCTAssertFalse(recording.toDriver.isEmpty)
        XCTAssertTrue(recording.handedOver.allSatisfy { $0.ms <= 625 }, "handover continued past give-up")
        XCTAssertTrue(recording.toDriver.allSatisfy { $0.ms <= 625 }, "driver recording continued past give-up")
        assertDelivered(recording)
    }

    func testMeasurementRejectsUnreadableOrUnplayablePacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LedTimingInvalid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try StorePackLedTimingTests.measurementTimeline(in: root))
        for missing in ["autoPlay", "keyLed", "info"] {
            _ = try LedTimingPackFiles.write(to: root, buttons: 8,
                                        keyLed: ["1 1 1 1": "o 1 1 a 5\n"], autoPlay: "o 1 1\n")
            try FileManager.default.removeItem(at: root.appendingPathComponent(missing))
            XCTAssertThrowsError(try StorePackLedTimingTests.measurementTimeline(in: root), missing)
            try FileManager.default.removeItem(at: root)
        }
        _ = try LedTimingPackFiles.write(to: root, buttons: 8,
                                    keyLed: ["1 1 1 1": "o 1 1 a 5\n"], autoPlay: "d 10\n")
        XCTAssertThrowsError(try StorePackLedTimingTests.measurementTimeline(in: root), "no LED commands")
    }

    private func record(keyLed: [String: String], autoPlay: String, releaseAll: Int64, giveUp: Int64) async throws -> LedPathRecording {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LedTimingPath-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try LedTimingPackFiles.write(to: root, buttons: 8, keyLed: keyLed, autoPlay: autoPlay, chains: 2)
        return try await LedPathRun(pack: LedTimingPackFiles.load(root), midiArrivals: LedTimingOptions.midiArrivals)
            .run(releaseAllAtMs: releaseAll, giveUpAtMs: giveUp)
    }

    private func assertDelivered(_ recording: LedPathRecording, file: StaticString = #filePath, line: UInt = #line) {
        let comparison = LedTimingComparison(expected: recording.handedOver, arrived: recording.toDriver)
        XCTAssertTrue(comparison.orderedAndComplete, comparison.differences.joined(separator: "\n"), file: file, line: line)
        if let departed = recording.departed {
            let midi = LedTimingComparison(expected: recording.toMidi, arrived: departed)
            XCTAssertTrue(midi.orderedAndComplete, midi.differences.joined(separator: "\n"), file: file, line: line)
        }
    }

    /// 63 pads pressed 5 ms apart for ten rounds, each flashing itself every millisecond for 40 ms
    /// (repeating a colour, as packs do), the top row also lighting a round LED, and one endless
    /// animation released halfway: about 8,000 commands a second at peak. No two animations touch the
    /// same LED within a few ticks of each other, so the order of every LED is fixed.
    func testDensePackReachesTheDriverInThePacksOrderWithNothingMissing() async throws {
        var keyLed: [String: String] = [:]
        for x in 1...8 {
            for y in 1...8 {
                let pass = "o \(x) \(y) a 5\nd 1\no \(x) \(y) a 5\nd 1\no \(x) \(y) a 21\nd 1\nf \(x) \(y)\nd 1\n"
                let round = y == 1 ? ("o mc \(x) a 9\n", "f mc \(x)\n") : ("", "")
                keyLed["1 \(x) \(y) 1"] = round.0 + String(repeating: pass, count: 10) + round.1
            }
        }
        keyLed["1 8 8 1"] = nil
        keyLed["1 8 8 0"] = "o 8 8 a 13\nd 60000\n"
        let pads = (1...8).flatMap { x in (1...8).map { y in (x, y) } }.filter { $0 != (8, 8) }
        var autoPlay = "o 8 8\n"
        for round in 0..<10 {
            for (x, y) in pads { autoPlay += "o \(x) \(y)\nd 2\nf \(x) \(y)\nd 3\n" }
            if round == 4 { autoPlay += "f 8 8\n" }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LedTimingDense-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = try LedTimingPackFiles.write(to: folder, buttons: 8, keyLed: keyLed, autoPlay: autoPlay)

        let releaseAll = IntendedLedTimeline.autoPlayLength(of: LedTimingPackFiles.load(root)) + 200
        let giveUp = releaseAll + 10_000
        let timeline = IntendedLedTimeline.of(LedTimingPackFiles.load(root), releaseAllAtMs: releaseAll, giveUpAtMs: giveUp)
        let recording = try await LedPathRun(pack: LedTimingPackFiles.load(root), midiArrivals: LedTimingOptions.midiArrivals)
            .run(releaseAllAtMs: releaseAll, giveUpAtMs: giveUp)
        let measurement = LedTimingMeasurement(name: "in-repo dense pack", timeline: timeline, recording: recording)
        let report = measurement.describe()
        print(report)
        add(XCTAttachment(string: report))

        XCTAssertGreaterThan(timeline.peakPerSecond, 5_000, "commands a second at peak")
        XCTAssertTrue(measurement.deliveredAsHandedOver, report)
        let result = measurement.packToDriver
        let differences = result.differences.joined(separator: "\n")
        XCTAssertEqual(result.reordered, 0, differences)
        XCTAssertEqual(result.missing, 0, differences)
        XCTAssertEqual(result.extra, 0, differences)
        XCTAssertEqual(result.matched, timeline.commands.count)
        XCTAssertEqual(recording.covered, 0)
        if let delivered = measurement.deliveredToMidi { XCTAssertTrue(delivered, report) }
    }
}

nonisolated enum LedTimingOptions {
    /// UNIPAD_LED_TIMING_MIDI=<arrivals file of ci/virtual-launchpad.sh>: runs also send MIDI to that
    /// VirtualLaunchpad and read when it arrived (T2).
    static var midiArrivals: URL? { ProcessInfo.processInfo.environment["UNIPAD_LED_TIMING_MIDI"].map { URL(fileURLWithPath: $0) } }
}
