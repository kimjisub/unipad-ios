/// The time a playback timeline (autoplay, lights) spent without a tick while the app was away.
///
/// A suspended app runs no ticks while the monotonic clock goes on, so a timeline that counted that
/// time would play everything that fell due meanwhile at once when the app comes back. That time is
/// not owed: the timeline goes on from where it was. While the app is away but still running (Control
/// Center pulled down) ticks keep coming and nothing is skipped; a gap while the app is in front (a
/// busy main thread) is left to the timeline, as before.
nonisolated struct SuspendedTime {
    /// Far longer than any tick of a running timeline.
    static let minimumGapMs: Int64 = 100

    private var away = false
    private var lastTick: Int64?

    mutating func appWentAway() {
        away = true
    }

    /// How much to skip at this tick: the gap since the last one, when the app was away meanwhile.
    mutating func tick(at now: Int64) -> Int64 {
        defer { lastTick = now }
        guard away, let lastTick, now - lastTick > Self.minimumGapMs else { return 0 }
        return now - lastTick
    }

    /// The app is in front again. The timeline's first tick after a suspension may run before or after
    /// this; whichever comes first skips the gap, and the other finds none.
    mutating func appReturned(at now: Int64) -> Int64 {
        let skipped = tick(at: now)
        away = false
        return skipped
    }

    /// The timeline stopped: the time until its next tick is not a gap.
    mutating func reset() {
        lastTick = nil
    }
}
