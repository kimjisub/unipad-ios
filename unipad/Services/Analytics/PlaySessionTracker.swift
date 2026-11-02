import Foundation

/// Tracks one visit to the play screen and emits each core event at most once:
///
/// - `pack_load`: when the pack and its sounds are ready (success), when loading fails, or when the
///   screen is left before loading finished (cancelled).
/// - `play_start`: on the first accepted human or automatic pad press after a successful load.
/// - `play_first_input`: on the first human pad press, including after autoplay started, with
///   whether it came from the screen or an external controller.
/// - `play_end`: when the screen is left after `play_start`, with the time spent playing.
///
/// `pack_load`, `play_start` and `play_end` also carry the last known `ScreenLayout` at that moment,
/// when there is one, so a visit that loaded, started or ended in a large window can be told apart.
final class PlaySessionTracker {
    private enum State {
        case idle
        case loading(startedAt: TimeInterval)
        case loaded
        case playing(startedAt: TimeInterval)
        case finished
    }

    private var state: State = .idle
    private var humanInputRecorded = false
    private var screenLayout: ScreenLayout?
    private let now: () -> TimeInterval
    private let log: (String, [String: String]) -> Void

    init(now: @escaping () -> TimeInterval, log: @escaping (String, [String: String]) -> Void) {
        self.now = now
        self.log = log
    }

    /// The play screen's window was laid out anew: shown, rotated or resized. A nil layout (a moment
    /// of undefined size) keeps the one known before.
    func screenLayoutChanged(_ layout: ScreenLayout?) {
        if let layout { screenLayout = layout }
    }

    func loadStarted() {
        guard case .idle = state else { return }
        state = .loading(startedAt: now())
    }

    func loadSucceeded() {
        guard case .loading(let startedAt) = state else { return }
        state = .loaded
        log(UsageEvent.packLoad, withScreenLayout([
            UsageParam.result: UsageResult.success.rawValue,
            UsageParam.durationBucket: DurationBucket.label(for: now() - startedAt),
        ]))
    }

    func loadFailed(_ errorType: UsageErrorType) {
        guard case .loading = state else { return }
        state = .finished
        log(UsageEvent.packLoad, withScreenLayout([
            UsageParam.result: UsageResult.failure.rawValue,
            UsageParam.errorType: errorType.rawValue,
        ]))
    }

    func playTriggered(_ trigger: PlayTrigger) {
        switch state {
        case .loaded:
            state = .playing(startedAt: now())
            log(UsageEvent.playStart, withScreenLayout([UsageParam.trigger: trigger.name]))
        case .playing:
            break
        case .idle, .loading, .finished:
            return
        }
        if case .pad(let source) = trigger, !humanInputRecorded {
            humanInputRecorded = true
            log(UsageEvent.playFirstInput, [
                UsageParam.trigger: trigger.name,
                UsageParam.inputSource: source.rawValue,
            ])
        }
    }

    func ended() {
        switch state {
        case .loading:
            log(UsageEvent.packLoad, withScreenLayout([UsageParam.result: UsageResult.cancelled.rawValue]))
        case .playing(let startedAt):
            log(UsageEvent.playEnd, withScreenLayout([UsageParam.durationBucket: DurationBucket.label(for: now() - startedAt)]))
        case .idle, .loaded, .finished:
            break
        }
        state = .finished
    }

    private func withScreenLayout(_ parameters: [String: String]) -> [String: String] {
        parameters.merging(screenLayout?.parameters ?? [:]) { current, _ in current }
    }
}
