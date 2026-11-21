#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
@testable import unipad

/// What a play screen suite needs to post the audio session's system notifications into a loaded
/// pack and read back what the engine and the screen did with them.
@MainActor
protocol PlayAudioSessionTesting {}

/// What the engine reported to the screen, in order, after the screen's own handler ran.
final class InterruptionReports {
    var all: [SoundEngine.Interruption] = []
}

/// A route as a route change notification carries it. The SDK gives routes and ports no public
/// initializer, and the engine reads only the outputs' port types.
final class RecordedRoute: AVAudioSessionRouteDescription, @unchecked Sendable {
    private let ports: [AVAudioSessionPortDescription]
    init(outputs: [AVAudioSession.Port]) {
        ports = outputs.map(RecordedPort.init)
        super.init()
    }
    override var outputs: [AVAudioSessionPortDescription] { ports }
}

final class RecordedPort: AVAudioSessionPortDescription, @unchecked Sendable {
    private let type: AVAudioSession.Port
    init(_ type: AVAudioSession.Port) {
        self.type = type
        super.init()
    }
    override var portType: AVAudioSession.Port { type }
}

extension PlayAudioSessionTesting {
    typealias Reports = InterruptionReports

    func interruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) -> Notification {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if shouldResume {
            info[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue
        }
        return Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: info)
    }

    /// `previous` is the route the notification says the session played to; nil leaves it out.
    func postRouteChange(_ reason: AVAudioSession.RouteChangeReason, previous: [AVAudioSession.Port]? = nil) {
        var info: [AnyHashable: Any] = [AVAudioSessionRouteChangeReasonKey: reason.rawValue]
        if let previous {
            info[AVAudioSessionRouteChangePreviousRouteKey] = RecordedRoute(outputs: previous)
        }
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: info)
    }

    /// The session now plays to `ports`, and the system says the old output went away. The ports are
    /// always set: the simulator's own route would otherwise decide whether the song pauses.
    func loseOutput(
        _ engine: SoundEngine, leaving ports: [AVAudioSession.Port], previous: [AVAudioSession.Port]? = nil
    ) {
        engine.currentOutputPorts = { ports }
        postRouteChange(.oldDeviceUnavailable, previous: previous)
    }

    /// Starts autoplay and waits until it has played `progress` steps.
    func startAutoplay(_ s: PlayUsageScenario, reaching progress: Int = 3) async throws -> AutoPlayRunner {
        let runner = try #require(s.vm.autoPlayRunner)
        s.vm.switchPlayMode(.autoPlay)
        try await s.waitWhile { runner.progress < progress }
        try #require(runner.progress >= progress, "autoplay never started")
        return runner
    }

    /// Taking the session back runs on the audio session worker and reports on the main queue.
    /// `untilSettled` also waits for a recovery still running after the session came back.
    func waitForRecovery(_ s: PlayUsageScenario, _ engine: SoundEngine, untilSettled: Bool = false) async throws {
        try await s.waitWhile { engine.isPlaybackSuppressed || (untilSettled && engine.isRecoveringPlayback) }
    }

    func observeInterruptions(_ engine: SoundEngine) -> Reports {
        let reports = Reports()
        let screen = engine.onInterruption
        engine.onInterruption = { interruption in
            screen?(interruption)
            reports.all.append(interruption)
        }
        return reports
    }

    func isPressedLit(_ s: PlayUsageScenario, x: Int, y: Int) -> Bool {
        s.vm.channelManager?.get(x: x, y: y, channel: .pressed) != nil
    }
}
#endif
