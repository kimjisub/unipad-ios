import Foundation
@testable import unipad

/// Observes the app's operations; an operation fixture is never loaded as a pack.
@MainActor
enum ConformanceProductObservation {
    private enum InputError: Error { case invalid(String) }

    static func actual(for sample: ConformanceCase, corpus: ConformanceCorpus, deps: ConformanceDeps) -> ConformanceActual? {
        guard let kind = sample.observation else {
            return sample.files.contains { $0.path == "operation.json" }
                ? .failed("operation.json requires a registered observation kind") : nil
        }
        if kind == "runner" || kind == "auto-map" {
            return sample.layer == "run" ? nil : .failed("\(kind) observation requires the run layer")
        }
        do {
            switch kind {
            case "audio-file":
                guard sample.files.count == 1, let file = sample.files.first else {
                    throw InputError.invalid("audio-file requires exactly one physical file")
                }
                return .value(facts(deps.inspectAudio(try corpus.bytes(of: file))))
            case "audio-cost":
                return .value(cost(deps.audioCost(try inputFacts(operation(sample, corpus)))))
            case "audio-wave":
                return .value(try wave(operation(sample, corpus), deps: deps))
            case "audio-selection":
                return .value(try selection(operation(sample, corpus)))
            default:
                return .failed("unregistered observation kind: \(kind)")
            }
        } catch {
            return .failed("\(sample.id): invalid \(kind) observation input: \(error)")
        }
    }

    private static func operation(_ sample: ConformanceCase, _ corpus: ConformanceCorpus) throws -> JSONValue {
        let files = sample.files.filter { $0.path == "operation.json" }
        guard files.count == 1, let file = files.first else { throw InputError.invalid("one operation.json is required") }
        let value = try JSONValue(data: corpus.bytes(of: file))
        guard value.object != nil else { throw InputError.invalid("operation.json must be an object") }
        return value
    }

    private static func integer(_ value: JSONValue?) throws -> Int {
        if let number = value?.int { return number }
        if let text = value?.string, let number = Int(text) { return number }
        throw InputError.invalid("an exact integer is required")
    }

    private static func inputFacts(_ value: JSONValue) throws -> AudioAdmission.Facts {
        try .init(sampleRate: integer(value["rate"]), channels: integer(value["channels"]), frames: integer(value["frames"]))
    }

    private static func reason(_ value: AudioAdmission.Exclusion?) -> JSONValue { value.map { .string($0.rawValue) } ?? .null }

    private static func cost(_ value: AudioAdmission.Cost) -> JSONValue {
        ["cost": .string(String(value.cost)), "exclusion": reason(value.exclusion)]
    }

    private static func facts(_ value: AudioAdmission.Inspection) -> JSONValue {
        guard let facts = value.facts else { return ["exclusion": reason(value.exclusion)] }
        return ["exclusion": nil, "rate": .int(facts.sampleRate), "channels": .int(facts.channels), "frames": .string(String(facts.frames))]
    }

    /// A sparse PCM file has real physical frames without allocating hundreds of megabytes of zeros.
    /// The misleading fact chunk is input, not the source of the observed frame count.
    private static func wave(_ input: JSONValue, deps: ConformanceDeps) throws -> JSONValue {
        let f = try inputFacts(input), claimed = try integer(input["claimedSeconds"])
        guard f.sampleRate > 0, f.channels > 0, f.frames >= 0, claimed >= 0,
              f.sampleRate <= Int(UInt32.max) / f.channels / 2,
              f.frames <= (Int(UInt32.max) - 48) / f.channels / 2,
              claimed <= Int(UInt32.max) / f.sampleRate else { throw InputError.invalid("wave recipe is out of bounds") }
        let size = f.frames * f.channels * 2
        var bytes = Data()
        func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func word(_ value: Int, _ width: Int) {
            for i in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        text("RIFF"); word(48 + size, 4); text("WAVEfmt "); word(16, 4)
        word(1, 2); word(f.channels, 2); word(f.sampleRate, 4); word(f.sampleRate * f.channels * 2, 4)
        word(f.channels * 2, 2); word(16, 2); text("fact"); word(4, 4); word(claimed * f.sampleRate, 4)
        text("data"); word(size, 4)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("conformance-wave-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try bytes.write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes.count + size))
        let inspection = deps.inspectAudio(try Data(contentsOf: file, options: .alwaysMapped))
        guard let measured = inspection.facts else { return ["exclusion": reason(inspection.exclusion)] }
        let admitted = deps.audioCost(measured)
        return ["frames": .string(String(measured.frames)), "cost": .string(String(admitted.cost)), "exclusion": reason(admitted.exclusion)]
    }

    private static func selection(_ input: JSONValue) throws -> JSONValue {
        guard let rows = input["references"]?.array, let bounds = input["bounds"]?.array, bounds.count == 3,
              let facts = input["facts"]?.object else { throw InputError.invalid("selection requires references, bounds and facts") }
        let references = try rows.map { row -> AudioAdmission.Reference in
            guard let values = row.array, values.count == 5, let identity = values[4].string else {
                throw InputError.invalid("invalid selection reference")
            }
            return try .init(chain: integer(values[0]), x: integer(values[1]), y: integer(values[2]), line: integer(values[3]), identity: identity)
        }
        var order: [String] = []
        let plan = try AudioAdmission.select(references, bounds: .init(chains: integer(bounds[0]), width: integer(bounds[1]), height: integer(bounds[2]))) { identity in
            order.append(identity)
            guard let values = facts[identity]?.array, values.count == 3 else { return .rejected(.readFailure) }
            return try .accepted(.init(sampleRate: integer(values[0]), channels: integer(values[1]), frames: integer(values[2])))
        }
        return [
            "order": .array(order.map(JSONValue.string)),
            "selected": .array(plan.files.filter { $0.exclusion == nil }.map { .string($0.identity) }),
            "exclusions": .array(plan.files.map { reason($0.exclusion) }),
            "reservedCost": .string(String(plan.reservedCost)),
        ]
    }
}
