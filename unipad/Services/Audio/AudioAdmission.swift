import Foundation

/// Structural admission is complete before decoding. This is not a device memory guarantee.
nonisolated enum AudioAdmission {
    static let singleLimit = 67_108_864
    static let packLimit = 134_217_728

    enum Exclusion: String, Error, Equatable {
        case invalidFormat = "INVALID_FORMAT"
        case readFailure = "READ_FAILURE"
        case sampleRate = "SAMPLE_RATE"
        case channels = "CHANNELS"
        case duration = "DURATION"
        case singleLimit = "SINGLE_LIMIT"
        case packLimit = "PACK_LIMIT"
    }
    struct Facts: Equatable {
        let sampleRate: Int
        let channels: Int
        /// Frames per channel, before decoder delay, padding and edit-list trimming.
        let frames: Int
    }
    enum Inspection: Equatable {
        case accepted(Facts)
        case rejected(Exclusion)
        var facts: Facts? { if case .accepted(let facts) = self { return facts }; return nil }
        var exclusion: Exclusion? { if case .rejected(let reason) = self { return reason }; return nil }
    }
    struct Cost: Equatable {
        let cost: Int
        let exclusion: Exclusion?
    }
    static func cost(_ facts: Facts) -> Cost {
        let rate = facts.sampleRate, channels = facts.channels, frames = facts.frames
        func rejected(_ reason: Exclusion) -> Cost { Cost(cost: 0, exclusion: reason) }
        guard (8_000...384_000).contains(rate) else { return rejected(.sampleRate) }
        guard (1...8).contains(channels) else { return rejected(.channels) }
        guard frames >= 0 else { return rejected(.invalidFormat) }
        // The operands are bounded before every multiplication and addition.
        guard frames <= 600 * rate else { return rejected(.duration) }
        let scaled: Int
        if rate < 48_000 {
            guard frames <= Int.max / 48_000 else { return rejected(.invalidFormat) }
            let numerator = frames * 48_000
            scaled = numerator / rate + (numerator % rate == 0 ? 0 : 1)
        } else { scaled = frames }
        let count = max(channels, 2)
        guard scaled <= singleLimit / count else { return rejected(.singleLimit) }
        return Cost(cost: scaled * count, exclusion: nil)
    }
    /// Zero-based coordinates; identity must be the resolved archive path, not its keySound spelling.
    struct Reference {
        let chain: Int
        let x: Int
        let y: Int
        let line: Int
        let identity: String
    }
    struct Bounds {
        let chains: Int
        let width: Int
        let height: Int
    }
    struct Selection: Equatable {
        let identity: String
        let cost: Int
        let exclusion: Exclusion?
    }
    /// Value semantics and immutable fields prevent a decoder from refunding reservations.
    struct Plan: Equatable {
        let files: [Selection]
        let reservedCost: Int
    }
    static func select(_ references: [Reference], bounds: Bounds,
                       inspect: (String) throws -> Inspection) throws -> Plan {
        guard bounds.chains >= 0, bounds.width >= 0, bounds.height >= 0 else { throw Exclusion.invalidFormat }
        let ordered = references.enumerated().filter {
            let r = $0.element
            return r.chain >= 0 && r.chain < bounds.chains && r.x >= 0 && r.x < bounds.width && r.y >= 0 && r.y < bounds.height
        }.sorted {
            let a = $0.element, b = $1.element
            if a.chain != b.chain { return a.chain < b.chain }
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            if a.line != b.line { return a.line < b.line }
            return $0.offset < $1.offset
        }
        var seen = Set<String>(), files = [Selection](), reserved = 0
        for item in ordered {
            let id = item.element.identity
            guard seen.insert(id).inserted else { continue }
            let inspection: Inspection
            do { inspection = try inspect(id) } catch { inspection = .rejected(.readFailure) }
            let result: Cost
            switch inspection {
            case .accepted(let facts): result = cost(facts)
            case .rejected(let reason): result = Cost(cost: 0, exclusion: reason)
            }
            let reason = result.exclusion ?? (result.cost > packLimit - reserved ? .packLimit : nil)
            let amount = reason == nil ? result.cost : 0
            reserved += amount // Checked against the remaining limit before adding.
            files.append(Selection(identity: id, cost: amount, exclusion: reason))
        }
        return Plan(files: files, reservedCost: reserved)
    }
}
