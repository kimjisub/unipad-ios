import Foundation

/// Runs `body`, returning a description of the Objective-C exception it raised, or nil when it
/// returned normally.
///
/// Reserved for the audio hot path: `AVAudioPlayerNode.play()` raises instead of throwing when its
/// engine is not rendering, and an NSException that crosses Swift frames terminates the app. The
/// guards in `AudioSessionGate` close the window they can see; this catches the rest, so the worst
/// case is one silent pad instead of a crash.
func runCatchingObjCException(_ body: () -> Void) -> String? {
    guard let exception = UPRunCatchingObjCException(body) else { return nil }
    return "\(exception.name.rawValue): \(exception.reason ?? "no reason given")"
}
