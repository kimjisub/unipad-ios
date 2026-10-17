import Foundation
import XCTest
@testable import unipad

/// Measures store packs, which stay out of the repository. Runs only when given a folder of unzipped
/// packs, for example the store's `https://unipack.unipad.io/store/<code>.zip` files, each unzipped
/// (with its sounds, which keySound wormholes need) into a folder named after the code:
///
///     TEST_RUNNER_UNIPAD_LED_TIMING_PACKS=/path/to/packs \
///     TEST_RUNNER_UNIPAD_LED_TIMING_MEASURE=_Some_Pack,_Other_Pack \
///     TEST_RUNNER_UNIPAD_LED_TIMING_OUT=/path/to/reports \
///     TEST_RUNNER_UNIPAD_LED_TIMING_MIDI=/path/to/arrivals.txt \
///     xcodebuild test … -only-testing:unipadTests/StorePackLedTimingTests
///
/// `testRankPacks` lists every pack with autoplay and keyLED by LED commands a second at peak.
/// `testMeasurePacks` plays each pack named in UNIPAD_LED_TIMING_MEASURE in real time (as long as its
/// autoplay) and fails when the driver does not receive exactly what LedRunner handed over, or receives
/// the pack's commands reordered, incomplete or with extra ones. With UNIPAD_LED_TIMING_MIDI set to the
/// arrivals file of a running ci/virtual-launchpad.sh, the commands also go out as MIDI to that virtual
/// Launchpad MK2, which must receive all of them in order. A run stopped at the give-up time reports
/// unmatched intended commands after the latest match as an incomplete observation, not a whole-pack
/// missing-command verdict. Missing commands before that point still fail.
/// Reordered/extra commands and every observed command's transport delivery are still checked. Reports go to UNIPAD_LED_TIMING_OUT
/// (an existing folder; a simulator can write host paths) and to the test's attachments.
@MainActor
final class StorePackLedTimingTests: XCTestCase {
    /// Autoplay ends with the song; trailing animations get this long before every pad is released.
    private static let tailMs: Int64 = 3_000
    private static let giveUpAfterMs: Int64 = 30_000

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func packsFolder() throws -> URL {
        let path = try XCTUnwrap(environment["UNIPAD_LED_TIMING_PACKS"])
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    override func setUpWithError() throws {
        try XCTSkipIf(environment["UNIPAD_LED_TIMING_PACKS"] == nil, "set UNIPAD_LED_TIMING_PACKS to a folder of unzipped packs")
    }

    func testRankPacks() throws {
        struct Ranked {
            let name: String
            let title: String
            let timeline: IntendedLedTimeline
        }
        var ranked: [Ranked] = []
        var skipped: [String] = []
        for source in try packSources() {
            guard let root = LedTimingPackFiles.packRoot(in: source) else {
                skipped.append("\(source.lastPathComponent) (no info file)")
                continue
            }
            let pack = LedTimingPackFiles.load(root)
            if !pack.autoPlayExist || !pack.keyLedExist {
                skipped.append("\(source.lastPathComponent) (autoplay \(pack.autoPlayExist), keyLED \(pack.keyLedExist))")
            } else {
                ranked.append(Ranked(name: source.lastPathComponent, title: pack.title, timeline: Self.timeline(for: pack)))
            }
        }
        ranked.sort { $0.timeline.peakPerSecond > $1.timeline.peakPerSecond }

        let byAverage = ranked.sorted { $0.timeline.averagePerSecond < $1.timeline.averagePerSecond }
        let median = byAverage.isEmpty ? nil : byAverage[byAverage.count / 2].name
        var text = "| # | pack | title | commands | play ms | per second (average) | per second (peak 1 s) | endless without delay |\n"
        text += "|---|---|---|---|---|---|---|---|\n"
        for (i, r) in ranked.enumerated() {
            let t = r.timeline
            text += "| \(i + 1) | \(r.name)\(r.name == median ? " (median average)" : "") | \(r.title) | \(t.commands.count) | "
                + "\(Int(t.lastT0)) | \(String(format: "%.0f", t.averagePerSecond)) | \(t.peakPerSecond) | \(t.delaylessEndlessAnimations) |\n"
        }
        text += "\nWithout autoplay or keyLED: \(skipped.joined(separator: ", "))\n"
        report(text, as: "ranking.md")
        let folder = try packsFolder().path
        XCTAssertFalse(ranked.isEmpty, "no pack with autoplay and keyLED in \(folder)")
    }

    func testMeasurePacks() async throws {
        let names = (environment["UNIPAD_LED_TIMING_MEASURE"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        try XCTSkipIf(names.isEmpty, "set UNIPAD_LED_TIMING_MEASURE to the packs to play")
        var failed: [String] = []
        for name in names {
            let source = try XCTUnwrap(try packSources().first { $0.lastPathComponent == name }, "\(name) is not in the packs folder")
            let root = try XCTUnwrap(LedTimingPackFiles.packRoot(in: source), "no info file in \(source.path)")
            let timeline = try Self.measurementTimeline(in: root)
            let releaseAll = timeline.autoPlayLengthMs + Self.tailMs
            let recording = try await LedPathRun(pack: LedTimingPackFiles.load(root), midiArrivals: LedTimingOptions.midiArrivals)
                .run(releaseAllAtMs: releaseAll, giveUpAtMs: releaseAll + Self.giveUpAfterMs)
            let measurement = LedTimingMeasurement(name: name, timeline: timeline, recording: recording)
            report(measurement.describe(), as: "\(name).txt")
            let comparison = measurement.packToDriver
            if recording.handedOver.isEmpty || !measurement.deliveredAsHandedOver
                || comparison.hasUnexpectedDifferences(allowMissingTail: !measurement.assessesPackCompleteness)
                || measurement.deliveredToMidi == false {
                failed.append(name)
            }
        }
        XCTAssertTrue(failed.isEmpty, "reordered, missing or extra commands: \(failed)")
    }

    static func measurementTimeline(in root: URL) throws -> IntendedLedTimeline {
        let pack = LedTimingPackFiles.load(root)
        guard !pack.criticalError else { throw MeasurementError.unreadablePack }
        guard pack.autoPlayExist, pack.keyLedExist else { throw MeasurementError.missingAutoPlayOrKeyLed }
        let timeline = timeline(for: pack)
        guard !timeline.commands.isEmpty else { throw MeasurementError.noLedCommands }
        return timeline
    }

    private enum MeasurementError: Error {
        case unreadablePack
        case missingAutoPlayOrKeyLed
        case noLedCommands
    }

    /// The timeline LedPathRun is compared with: every pad released `tailMs` after autoplay ends, and
    /// nothing recorded `giveUpAfterMs` after that.
    private static func timeline(for pack: UniPack) -> IntendedLedTimeline {
        let releaseAll = IntendedLedTimeline.autoPlayLength(of: pack) + tailMs
        return IntendedLedTimeline.of(pack, releaseAllAtMs: releaseAll, giveUpAtMs: releaseAll + giveUpAfterMs)
    }

    private func packSources() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: try packsFolder(), includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func report(_ text: String, as fileName: String) {
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        add(attachment)
        if let out = environment["UNIPAD_LED_TIMING_OUT"] {
            try? text.write(to: URL(fileURLWithPath: out).appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        }
    }
}
