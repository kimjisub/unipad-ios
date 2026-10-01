import AVFoundation
import XCTest
@testable import unipad

/// Real silent audio and the production screen model; no waits before stopping a repeated voice.
@MainActor
final class PlaybackStopTests: XCTestCase {
    private func pack(loop: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackStop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try "title=Playback Stop\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=1\n".write(to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav \(loop)\n".write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        try "on 1 1\noff 1 1\ndelay 100\non 1 2\noff 1 2\ndelay 100\non 1 3\noff 1 3\n".write(to: root.appendingPathComponent("autoPlay"), atomically: true, encoding: .utf8)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("sounds/a.wav"), settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        try file.write(from: buffer)
        return root
    }

    private func loaded(_ root: URL) async throws -> PlayViewModel {
        let vm = PlayViewModel()
        try await vm.loadUnipack(path: root.path)
        let deadline = Date().addingTimeInterval(15)
        while !vm.startReady && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(vm.startReady)
        _ = try XCTUnwrap(vm.soundEngine)
        return vm
    }

    func testRepeatedVoiceCanBeStoppedImmediately() async throws {
        let root = try pack(loop: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        for round in 0..<30 {
            let vm = try await loaded(root)
            let engine = try XCTUnwrap(vm.soundEngine)
            vm.padTouch(x: 0, y: 0, isDown: true)
            XCTAssertEqual(engine.playsStarted, 1)
            if round > 0 { try await Task.sleep(for: .milliseconds(round % 10)) }
            let began = Date()
            vm.cleanup()
            XCTAssertLessThan(Date().timeIntervalSince(began), 1)
            print("STOP repeated exit round=\(round) returned")
        }
    }

    func testRepeatedVoiceCanBeRetriggeredImmediately() async throws {
        let root = try pack(loop: 3)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = try await loaded(root)
        defer { vm.cleanup() }
        let engine = try XCTUnwrap(vm.soundEngine)
        for round in 0..<100 {
            let began = Date()
            vm.padTouch(x: 0, y: 0, isDown: true)
            vm.padTouch(x: 0, y: 0, isDown: true)
            XCTAssertLessThan(Date().timeIntervalSince(began), 1)
            try await Task.sleep(for: .milliseconds(round % 10))
        }
        XCTAssertEqual(engine.playsStarted, 200)
    }

    func testFiniteRepeatsFinishAndReleaseTheirVoice() async throws {
        for loop in [3, 50] {
            let root = try pack(loop: loop)
            defer { try? FileManager.default.removeItem(at: root) }
            let vm = try await loaded(root)
            let engine = try XCTUnwrap(vm.soundEngine)
            defer { vm.cleanup() }
            vm.padTouch(x: 0, y: 0, isDown: true)
            let deadline = Date().addingTimeInterval(5)
            while engine.activeVoiceCount > 0 && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(engine.repeatedBuffersScheduled, loop, "keySound stores total plays, not additional repeats")
            XCTAssertEqual(engine.activeVoiceCount, 0)
        }
    }

    func testStoppedRepeatCannotReviveAfterTheNodeIsReused() async throws {
        let root = try pack(loop: 50)
        defer { try? FileManager.default.removeItem(at: root) }
        // Alternate a repeated and an infinite sound on the same pad, sharing a decoded file.
        try "1 1 1 a.wav 50\n1 1 1 a.wav 0\n".write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let vm = try await loaded(root)
        let engine = try XCTUnwrap(vm.soundEngine)
        defer { vm.cleanup() }
        vm.padTouch(x: 0, y: 0, isDown: true)
        vm.padTouch(x: 0, y: 0, isDown: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(engine.repeatedBuffersScheduled, 1, "obsolete callback scheduled another repeat")
        XCTAssertEqual(engine.activeVoiceCount, 1, "obsolete callback released the replacement voice")
        vm.cleanup()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(engine.activeVoiceCount, 0)
        XCTAssertEqual(engine.repeatedBuffersScheduled, 1)
        XCTAssertTrue(engine.isPlaybackSuppressed)
    }

    func testStepPracticeCanLeaveOrSwitchModesRepeatedly() async throws {
        let root = try pack(loop: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        for round in 0..<120 {
            let vm = try await loaded(root)
            let runner = try XCTUnwrap(vm.autoPlayRunner)
            vm.switchPlayMode(.stepPractice)
            try await Task.sleep(for: .milliseconds(30 + round % 10 * 7))
            XCTAssertGreaterThan(runner.progress, 0, "step scan did not run")
            let began = Date()
            if round.isMultiple(of: 2) {
                vm.cleanup()
            } else {
                vm.padTouch(x: 0, y: 0, isDown: true)
                vm.switchPlayMode(.autoPlay)
                vm.switchPlayMode(.guidePlay)
                vm.switchPlayMode(.none)
                vm.cleanup()
            }
            XCTAssertLessThan(Date().timeIntervalSince(began), 1)
            XCTAssertFalse(runner.active)
            print("STOP step round=\(round) returned")
        }
    }
}
