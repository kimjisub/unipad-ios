import Foundation

/// Collects one result per case, prints it and keeps ios.json (read by report.mjs) current after every
/// case, because Swift Testing has no hook that runs after the last parameterized case.
final class ConformanceReport: @unchecked Sendable {
    static let shared = ConformanceReport()

    private struct Entry {
        let fingerprint: String
        let status: String
        let detail: String
        let actual: JSONValue
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var announced = false

    /// UNIPACK_CONFORMANCE_DUMP=1, and only that value: every result is written but no case is asserted,
    /// to look at differences before they are pinned in the corpus. Such a run is never a pass
    /// (`thisRunAssertedEveryCase` fails).
    static var recordOnly: Bool { ProcessInfo.processInfo.environment["UNIPACK_CONFORMANCE_DUMP"] == "1" }
    static let recordOnlyNotice = "UNIPACK_CONFORMANCE_DUMP=1: record-only run, no case was asserted"

    /// UNIPACK_CONFORMANCE_ONLY: only the cases whose id starts with it run; the others are left out of
    /// ios.json (unverified in the report). Such a run is never a pass either.
    static var onlyPrefix: String? { onlyPrefix(in: ProcessInfo.processInfo.environment) }
    static func onlyPrefix(in environment: [String: String]) -> String? {
        environment["UNIPACK_CONFORMANCE_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
    }
    static var partialNotice: String { "UNIPACK_CONFORMANCE_ONLY=\(onlyPrefix ?? ""): partial run, only cases starting with it were run" }

    /// What ios.json says about this run: "checked" only when every case ran and was asserted.
    static var assertions: String { recordOnly ? "skipped" : onlyPrefix != nil ? "partial" : "checked" }

    private let outputDirectory: URL?
    init(directory: URL? = nil) { outputDirectory = directory }

    private var directory: URL {
        if let outputDirectory { return outputDirectory }
        if let configured = ProcessInfo.processInfo.environment["UNIPACK_CONFORMANCE_OUT"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("unipack-conformance", isDirectory: true)
    }

    /// A corpus error replaces an earlier report, so readers cannot mistake stale cases for this run.
    func loadCorpus(using load: () throws -> ConformanceCorpus = { try ConformanceCorpus.load() }) throws -> ConformanceCorpus {
        do { return try load() }
        catch {
            lock.lock()
            entries.removeAll()
            write(.object([
                "platform": .string(ConformanceCorpus.platform), "assertions": "failed",
                "generatedAt": .string(ISO8601DateFormatter().string(from: Date())),
                "error": .string(String(describing: error)), "cases": [],
            ]))
            lock.unlock()
            throw error
        }
    }

    func record(_ conformanceCase: ConformanceCase, outcome: ConformanceOutcome, actual: JSONValue, corpus: ConformanceCorpus) {
        lock.lock()
        defer { lock.unlock() }
        entries[conformanceCase.id] = Entry(fingerprint: conformanceCase.fingerprint, status: outcome.status, detail: outcome.detail, actual: actual)
        if !announced {
            announced = true
            print("UNIPACK-CONFORMANCE-CORPUS \(JSONValue.object(["platform": .string(ConformanceCorpus.platform), "corpusSha256": .string(corpus.sha256), "cases": .int(corpus.cases.count), "source": .string(corpus.source)]).serialized())")
            print("UNIPACK-CONFORMANCE-OUT \(directory.path)")
            if Self.recordOnly { print("UNIPACK-CONFORMANCE-RECORD-ONLY \(Self.recordOnlyNotice)") }
            if Self.onlyPrefix != nil { print("UNIPACK-CONFORMANCE-PARTIAL \(Self.partialNotice)") }
        }
        print("UNIPACK-CONFORMANCE \(JSONValue.object(["platform": .string(ConformanceCorpus.platform), "id": .string(conformanceCase.id), "fingerprint": .string(conformanceCase.fingerprint), "status": .string(outcome.status)]).serialized())")
        flush(corpus: corpus)
    }

    private func flush(corpus: ConformanceCorpus) {
        let cases = entries.keys.sorted().map { id -> JSONValue in
            let entry = entries[id]!
            return .object(["id": .string(id), "fingerprint": .string(entry.fingerprint), "status": .string(entry.status), "detail": .string(entry.detail), "actual": entry.actual])
        }
        let report = JSONValue.object([
            "platform": .string(ConformanceCorpus.platform), "corpusSha256": .string(corpus.sha256),
            "generatedAt": .string(ISO8601DateFormatter().string(from: Date())), "assertions": .string(Self.assertions),
            "cases": .array(cases),
        ])
        write(report)
    }

    private func write(_ report: JSONValue) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((report.serialized() + "\n").utf8).write(to: directory.appendingPathComponent("\(ConformanceCorpus.platform).json"), options: .atomic)
        } catch {
            print("UNIPACK-CONFORMANCE-OUT-FAILED \(error)")
        }
    }
}
