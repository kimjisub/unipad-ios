import Foundation

/// Tracks one visit to the play screen and emits each core event at most once:
///
/// - `pack_load`: when the pack and its sounds are ready (success), when loading fails, or when the
///   screen is left before loading finished (cancelled).
/// - `play_start`: on the first pad press or autoplay start after a successful load.
/// - `play_end`: when the screen is left after `play_start`, with the time spent playing.
final class PlaySessionTracker {
    private enum State {
        case idle
        case loading(startedAt: TimeInterval)
        case loaded
        case playing(startedAt: TimeInterval)
        case finished
    }

    private var state: State = .idle
    private let now: () -> TimeInterval
    private let log: (String, [String: String]) -> Void

    init(now: @escaping () -> TimeInterval, log: @escaping (String, [String: String]) -> Void) {
        self.now = now
        self.log = log
    }

    func loadStarted() {
        guard case .idle = state else { return }
        state = .loading(startedAt: now())
    }

    func loadSucceeded() {
        guard case .loading(let startedAt) = state else { return }
        state = .loaded
        log(UsageEvent.packLoad, [
            UsageParam.result: UsageResult.success.rawValue,
            UsageParam.durationBucket: DurationBucket.label(for: now() - startedAt),
        ])
    }

    func loadFailed(_ errorType: UsageErrorType) {
        guard case .loading = state else { return }
        state = .finished
        log(UsageEvent.packLoad, [
            UsageParam.result: UsageResult.failure.rawValue,
            UsageParam.errorType: errorType.rawValue,
        ])
    }

    func playTriggered(_ trigger: PlayTrigger) {
        guard case .loaded = state else { return }
        state = .playing(startedAt: now())
        log(UsageEvent.playStart, [UsageParam.trigger: trigger.rawValue])
    }

    func ended() {
        switch state {
        case .loading:
            log(UsageEvent.packLoad, [UsageParam.result: UsageResult.cancelled.rawValue])
        case .playing(let startedAt):
            log(UsageEvent.playEnd, [UsageParam.durationBucket: DurationBucket.label(for: now() - startedAt)])
        case .idle, .loaded, .finished:
            break
        }
        state = .finished
    }
}
