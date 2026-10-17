import Foundation

/// Commands that arrived, set against the ones expected: the pack's intent against the driver, or
/// LedRunner's output against the driver. Each LED is compared on its own: its sequence of codes as
/// they arrived against the sequence expected, matched by longest common subsequence. An expected code
/// left unmatched but arriving elsewhere in that LED's sequence counts as reordered; otherwise it is
/// missing. A code that arrived and is left unmatched after that is extra.
nonisolated struct LedTimingComparison {
    struct Latency {
        let t0: Double
        let ms: Double
    }

    /// Two LedRunner ticks: closer than this, two commands can share a tick and leave in either order.
    static let overtakeMs = 8.0
    /// The largest unmatched middle of one LED's sequences compared cell by cell (4 bytes a cell).
    private static let maxDiffCells = 25_000_000
    private static let maxReportedDifferences = 10

    let expected: Int
    let arrived: Int
    let matched: Int
    let reordered: Int
    let missing: Int
    let extra: Int
    /// Matched commands that arrived after one expected more than `overtakeMs` later, on any LED.
    let overtaken: Int
    /// LEDs whose differing middle was too long to compare, so it all counts as missing and extra.
    let uncompared: Int
    /// Arrival minus expected time of each matched command, in expected order.
    let latencies: [Latency]
    /// The first few LEDs whose sequence differs, for reproducing it.
    let differences: [String]

    var orderedAndComplete: Bool { reordered == 0 && missing == 0 && extra == 0 }

    private var sorted: [Double] { latencies.map(\.ms).sorted() }
    var median: Double { Self.percentile(sorted, 50) }
    var p95: Double { Self.percentile(sorted, 95) }
    var max: Double { latencies.map(\.ms).max() ?? .nan }

    /// Least-squares slope of latency over expected time, in ms per minute of play: above 0 means it builds up.
    var buildUpPerMinute: Double {
        guard latencies.count >= 2 else { return 0 }
        let meanT = latencies.reduce(0) { $0 + $1.t0 } / Double(latencies.count)
        let meanL = latencies.reduce(0) { $0 + $1.ms } / Double(latencies.count)
        var num = 0.0
        var den = 0.0
        for l in latencies {
            num += (l.t0 - meanT) * (l.ms - meanL)
            den += (l.t0 - meanT) * (l.t0 - meanT)
        }
        return den == 0 ? 0 : num / den * 60_000
    }

    /// Median latency of the matched commands expected in each tenth of the play time.
    var medianByTenth: [Double] {
        guard let last = latencies.map(\.t0).max() else { return [] }
        let end = last + 1
        return (0..<10).map { i in
            Self.percentile(latencies.filter { Int($0.t0 * 10 / end) == i }.map(\.ms).sorted(), 50)
        }
    }

    /// The nearest-rank `p`th percentile of ascending `sorted`.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[Swift.min(Swift.max(rank, 0), sorted.count - 1)]
    }

    init(expected: [LedCommand], arrived: [LedCommand]) {
        let want = Dictionary(grouping: expected.indices, by: { expected[$0].target })
        let got = Dictionary(grouping: arrived.indices, by: { arrived[$0].target })
        var matched = 0
        var reordered = 0
        var missing = 0
        var extra = 0
        var uncompared = 0
        var latencies: [Latency] = []
        var expectedTimeOfArrival = [Double?](repeating: nil, count: arrived.count)
        var differences: [String] = []

        let leds = Set(want.keys).union(got.keys).sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        for led in leds {
            let w = want[led] ?? []
            let g = got[led] ?? []
            let (pairs, compared) = Self.commonSubsequence(w.map { expected[$0].code }, g.map { arrived[$0].code })
            if !compared { uncompared += 1 }
            matched += pairs.count
            for (i, j) in pairs {
                latencies.append(Latency(t0: expected[w[i]].ms, ms: arrived[g[j]].ms - expected[w[i]].ms))
                expectedTimeOfArrival[g[j]] = expected[w[i]].ms
            }
            if pairs.count == w.count && pairs.count == g.count { continue }

            let matchedWant = Set(pairs.map(\.0))
            let matchedGot = Set(pairs.map(\.1))
            var unmatchedGot = g.indices.filter { !matchedGot.contains($0) }.map { arrived[g[$0]].code }
            for i in w.indices where !matchedWant.contains(i) {
                if let k = unmatchedGot.firstIndex(of: expected[w[i]].code) {
                    unmatchedGot.remove(at: k)
                    reordered += 1
                } else {
                    missing += 1
                }
            }
            extra += unmatchedGot.count
            if differences.count < Self.maxReportedDifferences {
                differences.append(Self.describe(led, w.map { expected[$0] }, g.map { arrived[$0] }))
            }
        }

        var overtaken = 0
        var latestIntended = -Double.infinity
        for t0 in expectedTimeOfArrival {
            guard let t0 else { continue }
            if t0 + Self.overtakeMs < latestIntended { overtaken += 1 }
            latestIntended = Swift.max(latestIntended, t0)
        }

        self.expected = expected.count
        self.arrived = arrived.count
        self.matched = matched
        self.reordered = reordered
        self.missing = missing
        self.extra = extra
        self.overtaken = overtaken
        self.uncompared = uncompared
        self.latencies = latencies.sorted { $0.t0 < $1.t0 }
        self.differences = differences
    }

    /// Index pairs of a longest common subsequence, and whether its middle could be compared. The
    /// sequences are usually equal or nearly so, so the shared head and tail are matched directly and
    /// only the part between them is compared cell by cell.
    private static func commonSubsequence(_ a: [Int], _ b: [Int]) -> (pairs: [(Int, Int)], compared: Bool) {
        var head = 0
        while head < a.count && head < b.count && a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head && tail < b.count - head && a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        var pairs = (0..<head).map { ($0, $0) }
        let n = a.count - head - tail
        let m = b.count - head - tail
        var compared = true
        if n > 0 && m > 0 {
            if n * m <= maxDiffCells {
                let width = m + 1
                var table = [Int32](repeating: 0, count: (n + 1) * width)
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        table[i * width + j] = a[head + i] == b[head + j]
                            ? table[(i + 1) * width + j + 1] + 1
                            : Swift.max(table[(i + 1) * width + j], table[i * width + j + 1])
                    }
                }
                var i = 0
                var j = 0
                while i < n && j < m {
                    if a[head + i] == b[head + j] {
                        pairs.append((head + i, head + j))
                        i += 1
                        j += 1
                    } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                        i += 1
                    } else {
                        j += 1
                    }
                }
            } else {
                compared = false
            }
        }
        for k in 0..<tail { pairs.append((a.count - tail + k, b.count - tail + k)) }
        return (pairs, compared)
    }

    private static func describe(_ led: LedTarget, _ want: [LedCommand], _ got: [LedCommand]) -> String {
        var first = 0
        while first < want.count && first < got.count && want[first].code == got[first].code { first += 1 }
        let from = Swift.max(first - 2, 0)
        func window(_ commands: [LedCommand]) -> String {
            guard from < commands.count else { return "" }
            return commands[from..<Swift.min(commands.count, first + 4)]
                .map { "\($0.code)@\(String(format: "%.1f", $0.ms))" }
                .joined(separator: ", ")
        }
        return "\(led): \(want.count) expected, \(got.count) arrived; from #\(from) expected [\(window(want))] arrived [\(window(got))]"
    }
}
