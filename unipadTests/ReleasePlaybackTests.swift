#if DEBUG || UNIPAD_RELEASE_TESTS
import XCTest
@testable import unipad

@MainActor
final class ReleasePlaybackTests: XCTestCase {
    private func withPack(script: String? = nil, _ check: (PlayViewModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try ReleaseTestSupport.makePack(at: root, title: "Playback Assertions")
        if let script {
            try script.write(to: root.appendingPathComponent("autoPlay"), atomically: true, encoding: .utf8)
        }
        let vm = PlayViewModel()
        defer { vm.cleanup() }
        try await vm.loadUnipack(path: root.path)
        let deadline = Date().addingTimeInterval(5)
        while !vm.startReady && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(vm.startReady)
        try await check(vm)
    }

    func testTwoHeldPadsRequestTheirSoundsLightAndChainSelection() async throws {
        try await withPack { vm in
            let engine = try XCTUnwrap(vm.soundEngine)
            vm.padTouch(x: 0, y: 0, isDown: true)
            vm.padTouch(x: 0, y: 1, isDown: true)
            XCTAssertEqual(engine.playsStarted, 2)
            let deadline = Date().addingTimeInterval(2)
            while vm.channelManager?.get(x: 0, y: 0, channel: .led) == nil && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let led = try XCTUnwrap(vm.channelManager?.get(x: 0, y: 0, channel: .led))
            XCTAssertEqual(led.code, 5)
            vm.selectChain(1)
            XCTAssertEqual(vm.chain.value, 1)
            vm.padTouch(x: 0, y: 0, isDown: true)
            XCTAssertEqual(engine.playsStarted, 3, "chain 2 must resolve its own sound mapping")
        }
    }

    func testAutoplayPauseFreezesProgressResumeAndStopClearState() async throws {
        try await withPack(script: "on 1 1\ndelay 150\noff 1 1\ndelay 150\non 1 2\ndelay 150\noff 1 2\n") { vm in
            vm.switchPlayMode(.autoPlay)
            let runner = try XCTUnwrap(vm.autoPlayRunner)
            let deadline = Date().addingTimeInterval(2)
            while runner.progress < 3 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertGreaterThanOrEqual(runner.progress, 3)
            XCTAssertTrue(vm.isAutoPlayPlaying)
            vm.autoPlayPause()
            let pausedProgress = runner.progress
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(runner.progress, pausedProgress)
            XCTAssertFalse(vm.isAutoPlayPlaying)
            vm.autoPlayResume()
            XCTAssertTrue(vm.isAutoPlayPlaying)
            XCTAssertTrue(runner.playmode)
            let resumeDeadline = Date().addingTimeInterval(2)
            while runner.progress == pausedProgress && Date() < resumeDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(runner.progress, pausedProgress, "resume must advance the sequence again")
            vm.stopAutoPlay()
            XCTAssertFalse(runner.active)
            XCTAssertFalse(vm.isAutoPlayPlaying)
            XCTAssertFalse(vm.autoPlayControlVisible)
        }
    }
}
#endif
