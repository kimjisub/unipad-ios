#if DEBUG || UNIPAD_RELEASE_TESTS
import Foundation
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif

/// Holds only the isolated sound-failure UI fixture, on the loader's worker, until connection
/// help is on screen. No file count or decoding duration establishes the ordering.
nonisolated final class ReleaseTestSoundLoadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var phase = "waiting"
    private let started = ProcessInfo.processInfo.systemUptime
    private var events: [String] = []

    static func configured(defaults: UserDefaults) -> ReleaseTestSoundLoadGate? {
        guard let token = defaults.string(forKey: "UniPadReleaseTest"), UUID(uuidString: token) != nil,
              defaults.string(forKey: "UniPadUITestLibrary") == "sound-failure",
              defaults.bool(forKey: "UniPadReleaseHoldSoundLoad") else { return nil }
        return ReleaseTestSoundLoadGate()
    }

    var status: String { condition.withLock { phase } }
    var timeline: String { condition.withLock { events.joined(separator: ", ") } }

    private func record(_ next: String) {
        phase = next
        let event = "\(next)=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s"
        events.append(event)
        print("SOUND-LOAD-RETURN \(event)")
    }

    func observe(_ event: SoundEngine.LoadingEvent) {
        guard event == .loadStarted else { return }
        condition.lock()
        defer { condition.unlock() }
        guard !released else { return }
        record("holding")
        while !released { condition.wait() }
    }

    func connectionHelpAppeared() {
        condition.lock()
        defer { condition.unlock() }
        guard !released else { return }
        record(phase == "holding" ? "released-under-help" : "help-before-load")
        released = true
        condition.broadcast()
    }

    func completed(failed: Bool, covered: Bool) {
        condition.withLock {
            record(phase == "released-under-help" && failed && covered ? "failed-under-cover" : "unexpected-completion")
        }
    }

    func cancel() {
        condition.lock()
        defer { condition.unlock() }
        if !released { record("cancelled") }
        released = true
        condition.broadcast()
    }
}

extension ReleaseTestSupport {
    static let soundLoadGate = ReleaseTestSoundLoadGate.configured(defaults: .standard)
}

#if canImport(UIKit)
/// A read-only accessibility probe remains queryable while the device screen covers Play.
struct ReleaseTestSoundLoadStatusView: UIViewRepresentable {
    let gate: ReleaseTestSoundLoadGate

    func makeUIView(context: Context) -> UIView {
        let view = StatusView(gate: gate)
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = "test.soundLoadState"
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class StatusView: UIView {
        let gate: ReleaseTestSoundLoadGate

        init(gate: ReleaseTestSoundLoadGate) {
            self.gate = gate
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var accessibilityLabel: String? {
            get { gate.timeline }
            set {}
        }
        override var accessibilityValue: String? {
            get { gate.status }
            set {}
        }
    }
}
#endif
#endif
