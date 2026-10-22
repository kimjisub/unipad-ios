import Foundation

/// One run set against the pack's intent (T1 − T0) and against what LedRunner handed over.
nonisolated struct LedTimingMeasurement {
    let name: String
    let timeline: IntendedLedTimeline
    let recording: LedPathRecording
    let packToDriver: LedTimingComparison
    let runnerToDriver: LedTimingComparison
    let packToRunner: LedTimingComparison
    /// What the driver was asked to send against what arrived at the VirtualLaunchpad (T2 − T1).
    let driverToMidi: LedTimingComparison?
    /// The pack's intent against what arrived at the VirtualLaunchpad (T2 − T0), repaints left out;
    /// only when everything sent arrived in order, which places each arrival.
    let packToMidi: LedTimingComparison?

    init(name: String, timeline: IntendedLedTimeline, recording: LedPathRecording) {
        self.name = name
        self.timeline = timeline
        self.recording = recording
        packToDriver = LedTimingComparison(expected: timeline.commands, arrived: recording.toDriver)
        runnerToDriver = LedTimingComparison(expected: recording.handedOver, arrived: recording.toDriver)
        packToRunner = LedTimingComparison(expected: timeline.commands, arrived: recording.handedOver)
        if let departed = recording.departed {
            driverToMidi = LedTimingComparison(expected: recording.toMidi, arrived: departed)
            if Self.same(recording.toMidi, departed) {
                let ledPath = departed.indices.filter { !recording.toMidiRepaints[$0] }.map { departed[$0] }
                packToMidi = LedTimingComparison(expected: timeline.commands.filter { VirtualLaunchpad.addresses($0.target) }, arrived: ledPath)
            } else {
                packToMidi = nil
            }
        } else {
            driverToMidi = nil
            packToMidi = nil
        }
    }

    private static func same(_ a: [LedCommand], _ b: [LedCommand]) -> Bool {
        a.map { [$0.target.x, $0.target.y, $0.code] } == b.map { [$0.target.x, $0.target.y, $0.code] }
    }

    /// Everything the driver was asked to send reached the VirtualLaunchpad, in the same order, and
    /// nothing else did; nil when the run sent no MIDI.
    var deliveredToMidi: Bool? {
        recording.departed.map { Self.same(recording.toMidi, $0) }
    }

    /// Every command LedRunner handed over reached the driver, in the same order, and nothing else did.
    var deliveredAsHandedOver: Bool { Self.same(recording.handedOver, recording.toDriver) }

    /// A forced cutoff can hide late commands at the observation boundary. It cannot establish
    /// whole-pack completeness; transport delivery is still checked for every observed command.
    var assessesPackCompleteness: Bool { recording.cutoffMs == nil }

    func describe() -> String {
        let pack = packToDriver
        var lines: [String] = []
        lines.append("LED timing: \(name)")
        lines.append("  pack: \(pack.expected) commands over \(Int(timeline.lastT0)) ms, "
            + "\(Self.f0(timeline.averagePerSecond))/s average, \(timeline.peakPerSecond)/s at peak"
            + (timeline.delaylessEndlessAnimations > 0 ? ", \(timeline.delaylessEndlessAnimations) endless animations without delay" : ""))
        lines.append("  LedRunner -> driver: \(runnerToDriver.expected) handed over, \(runnerToDriver.arrived) arrived, "
            + "same order \(deliveredAsHandedOver), ms median \(Self.ms(runnerToDriver.median)) p95 \(Self.ms(runnerToDriver.p95)) max \(Self.ms(runnerToDriver.max))")
        let comparisonLabel: String
        if let cutoff = recording.cutoffMs {
            comparisonLabel = "partial observation differs"
            lines.append("  observation stopped at \(cutoff) ms; whole-pack completeness not assessed; "
                + "unobserved window \(Self.ms(Double(cutoff) - LedTimingComparison.cutoffWindowMs))..<\(cutoff) ms")
            lines.append("  partial pack -> driver: matched \(pack.matched), reordered \(pack.reordered), "
                + "unmatched intended \(pack.missing), missing before cutoff window \(pack.unexpectedMissing(cutoffMs: cutoff)), extra \(pack.extra), repaints \(recording.repaints), "
                + "LEDs too long to compare \(pack.uncompared)")
        } else {
            comparisonLabel = "pack -> driver differs"
            lines.append("  pack -> driver: matched \(pack.matched), reordered \(pack.reordered), missing \(pack.missing), extra \(pack.extra), "
                + "covered \(recording.covered), overtaken by more than \(Int(LedTimingComparison.overtakeMs)) ms \(pack.overtaken), "
                + "repaints \(recording.repaints), LEDs too long to compare \(pack.uncompared)")
        }
        lines.append("  pack -> LedRunner handover ms: median \(Self.ms(packToRunner.median)), p95 \(Self.ms(packToRunner.p95)), max \(Self.ms(packToRunner.max))")
        lines.append("  T1-T0 ms: median \(Self.ms(pack.median)), p95 \(Self.ms(pack.p95)), max \(Self.ms(pack.max)), "
            + "build-up \(Self.ms(pack.buildUpPerMinute)) ms/min, median by tenth \(pack.medianByTenth.map(Self.ms).joined(separator: " "))")
        if let midi = driverToMidi {
            lines.append("  driver -> virtual Launchpad MK2 (T2-T1): \(midi.expected) sent, \(midi.arrived) arrived, same order \(deliveredToMidi ?? false), "
                + "reordered \(midi.reordered), missing \(midi.missing), extra \(midi.extra), "
                + "ms median \(Self.ms(midi.median)) p95 \(Self.ms(midi.p95)) max \(Self.ms(midi.max))")
        }
        if let packMidi = packToMidi {
            lines.append("  T2-T0 ms (MK2 LEDs only, \(packMidi.matched) matched): median \(Self.ms(packMidi.median)), p95 \(Self.ms(packMidi.p95)), max \(Self.ms(packMidi.max)), "
                + "build-up \(Self.ms(packMidi.buildUpPerMinute)) ms/min")
        }
        let pressDelays = zip(recording.pressTimes, timeline.pressTimes).map { $0 - Double($1) }.sorted()
        if let last = pressDelays.last {
            lines.append("  autoplay press reaching the play screen, ms after intended: median \(Self.ms(LedTimingComparison.percentile(pressDelays, 50))), "
                + "p95 \(Self.ms(LedTimingComparison.percentile(pressDelays, 95))), max \(Self.ms(last)) "
                + "(\(recording.pressTimes.count) of \(timeline.pressTimes.count) presses)")
        }
        lines.append("  \(Self.environment())")
        lines += runnerToDriver.differences.map { "  LedRunner -> driver differs: \($0)" }
        lines += (driverToMidi?.differences ?? []).map { "  driver -> virtual Launchpad differs: \($0)" }
        lines += pack.differences.map { "  \(comparisonLabel): \($0)" }
        return lines.joined(separator: "\n")
    }

    /// The machine a run's latency belongs to.
    static func environment() -> String {
        let env = ProcessInfo.processInfo.environment
        var load = [Double](repeating: .nan, count: 3)
        _ = getloadavg(&load, 3)
        let device = env["SIMULATOR_MODEL_IDENTIFIER"].map { "simulator \($0) iOS \(env["SIMULATOR_RUNTIME_VERSION"] ?? "?")" } ?? "device"
        return "\(device), \(ProcessInfo.processInfo.operatingSystemVersionString), "
            + "\(ProcessInfo.processInfo.activeProcessorCount) cores, host load average \(String(format: "%.1f", load[0]))"
    }

    private static func ms(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func f0(_ value: Double) -> String { String(format: "%.0f", value) }
}
