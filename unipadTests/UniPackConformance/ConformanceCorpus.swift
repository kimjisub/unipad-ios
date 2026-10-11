import CryptoKit
import Foundation

/// The shared conformance corpus (meta/unipack-conformance in unipad.io) as this platform reads it.
/// Expected results are only compared, never produced, here.
struct ConformanceFile {
    let path: String
    let text: String?
    let base64: String?
    let asset: String?
}

struct ConformanceKnown {
    let status: String
    let actual: JSONValue
    let note: String
}

struct ConformanceCase {
    let id: String
    let layer: String
    let title: String
    let files: [ConformanceFile]
    let fingerprint: String
    let determined: Bool
    let expected: JSONValue?
    let question: String?
    let scenario: [JSONValue]
    let known: [String: ConformanceKnown]
    /// Per platform, why its harness cannot observe this case; it is unverified there and not run.
    let unobserved: [String: String]
}

struct ConformanceCorpus {
    let sha256: String
    let source: String
    let assets: [String: Data]
    let cases: [ConformanceCase]

    static let platform = "ios"

    enum LoadError: Error, CustomStringConvertible {
        case missing
        case invalid(String)
        case digest(String)

        var description: String {
            switch self {
            case .missing: return "corpus.json is neither in the test bundle nor next to the test sources"
            case .invalid(let reason): return "corpus.json is invalid: \(reason)"
            case .digest(let reason): return reason
            }
        }
    }

    /// Keep one invocation when discovery fails; it reloads the corpus and reports the actual error.
    /// An empty parameter list would silently omit the case runner and leave an old report behind.
    static func caseIDs(load: () throws -> ConformanceCorpus = { try Self.load() }, onlyPrefix: String? = nil) -> [String] {
        do { return try load().cases.map(\.id).filter { onlyPrefix.map($0.hasPrefix) ?? true } }
        catch { return ["corpus-load-failed"] }
    }

    private final class BundleLocator {}

    /// The copy in the test bundle (the synchronized group ships it as a resource); the copy beside
    /// the sources is the fallback, and `source` says which one was read.
    static func load(sourceFile: String = #filePath) throws -> ConformanceCorpus {
        let bundle = Bundle(for: BundleLocator.self)
        let url: URL
        let source: String
        if let bundled = bundle.url(forResource: "corpus", withExtension: "json")
            ?? bundle.url(forResource: "corpus", withExtension: "json", subdirectory: "UniPackConformance") {
            url = bundled
            source = "bundle"
        } else {
            let beside = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().appendingPathComponent("corpus.json")
            guard FileManager.default.fileExists(atPath: beside.path) else { throw LoadError.missing }
            url = beside
            source = "source-tree"
        }
        let data = try Data(contentsOf: url)
        let digestFile = try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("corpus.sha256"), encoding: .utf8)
        _ = try verifyDigest(of: data, digestFile: digestFile)
        return try parse(data, source: source)
    }

    /// The sha256 of the corpus.json bytes, after checking it against the corpus.sha256 that unipad.io's
    /// build-corpus.mjs writes and sync.mjs copies beside it. A copy without that file, or one that does
    /// not hash to it, is refused.
    static func verifyDigest(of data: Data, digestFile: String?) throws -> String {
        let actual = sha256Hex(data)
        guard let digestFile else {
            throw LoadError.digest("corpus.sha256 is missing beside corpus.json; copy both with unipad.io meta/unipack-conformance/sync.mjs")
        }
        let declared = String(digestFile.prefix(64))
        guard declared.count == 64, declared.allSatisfy({ "0123456789abcdef".contains($0) }), digestFile == declared + "  corpus.json\n" else {
            throw LoadError.digest("corpus.sha256 is not one \"<sha256>  corpus.json\" line: \(digestFile.debugDescription)")
        }
        guard declared == actual else { throw LoadError.digest("corpus.json hashes to \(actual), corpus.sha256 declares \(declared)") }
        return actual
    }

    static func parse(_ data: Data, source: String) throws -> ConformanceCorpus {
        let root = try JSONValue(data: data)
        guard let assetObject = root["assets"]?.object, let caseArray = root["cases"]?.array else {
            throw LoadError.invalid("no assets or cases")
        }
        let assets = try assetObject.mapValues { value -> Data in
            guard let text = value["base64"]?.string, let bytes = Data(base64Encoded: text) else { throw LoadError.invalid("asset without base64") }
            return bytes
        }
        let cases = try caseArray.map { value -> ConformanceCase in
            guard let id = value["id"]?.string, let layer = value["layer"]?.string, let title = value["title"]?.string,
                  let fingerprint = value["fingerprint"]?.string, let files = value["files"]?.array
            else { throw LoadError.invalid("a case lacks id, layer, title, fingerprint or files") }
            // A misspelt or missing expectation must not quietly make a case undetermined, which never fails.
            let determined: Bool
            switch value["expectation"]?.string {
            case "determined": determined = true
            case "undetermined": determined = false
            case let other: throw LoadError.invalid("\(id): expectation is \(other.map { "\"\($0)\"" } ?? "missing"), not determined or undetermined")
            }
            let known = (value["known"]?.object ?? [:]).compactMapValues { pin -> ConformanceKnown? in
                guard let status = pin["status"]?.string, let actual = pin["actual"], let note = pin["note"]?.string else { return nil }
                return ConformanceKnown(status: status, actual: actual, note: note)
            }
            return ConformanceCase(
                id: id, layer: layer, title: title,
                files: files.compactMap { file in
                    guard let path = file["path"]?.string else { return nil }
                    return ConformanceFile(path: path, text: file["text"]?.string, base64: file["base64"]?.string, asset: file["asset"]?.string)
                },
                fingerprint: fingerprint,
                determined: determined,
                expected: value["expected"],
                question: value["question"]?.string,
                scenario: value["scenario"]?.array ?? [],
                known: known,
                unobserved: (value["unobserved"]?.object ?? [:]).compactMapValues(\.string)
            )
        }
        return ConformanceCorpus(sha256: sha256Hex(data), source: source, assets: assets, cases: cases)
    }

    func bytes(of file: ConformanceFile) throws -> Data {
        if let text = file.text { return Data(text.utf8) }
        if let base64 = file.base64, let data = Data(base64Encoded: base64) { return data }
        if let asset = file.asset, let data = assets[asset] { return data }
        throw LoadError.invalid("file \(file.path) has no content")
    }

    /// sha256 over the files sorted by the UTF-8 bytes of their path; per file
    /// `UTF8(path) 0x00 decimal(length) 0x00 bytes 0x0A`.
    func fingerprint(of files: [ConformanceFile]) throws -> String {
        var hasher = SHA256()
        let sorted = files.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        for file in sorted {
            let content = try bytes(of: file)
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(content.count).utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: content)
            hasher.update(data: Data([10]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Refuses a case whose files no longer hash to the fingerprint it declares.
    func verifyFingerprint(of conformanceCase: ConformanceCase) throws {
        let actual = try fingerprint(of: conformanceCase.files)
        guard actual == conformanceCase.fingerprint else {
            throw LoadError.invalid("\(conformanceCase.id): input files hash to \(actual), the case declares \(conformanceCase.fingerprint)")
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Classification

enum ConformanceStatus: String {
    case pass, fail, unsupported, unverified
    case intendedDifference = "intended-difference"
}

struct ConformanceOutcome: Equatable {
    let status: String
    /// A failure nothing in the corpus accounts for, or a pinned one that changed or went away.
    let unexpected: Bool
    let detail: String
}

extension ConformanceCase {
    func classify(_ actual: JSONValue, platform: String = ConformanceCorpus.platform) -> ConformanceOutcome {
        guard determined else {
            return ConformanceOutcome(status: ConformanceStatus.unverified.rawValue, unexpected: false, detail: "no doc or stated intent decides this: \(question ?? "")")
        }
        let pin = known[platform]
        if actual == expected {
            return pin == nil
                ? ConformanceOutcome(status: ConformanceStatus.pass.rawValue, unexpected: false, detail: "")
                : ConformanceOutcome(status: ConformanceStatus.pass.rawValue, unexpected: true, detail: "a pinned difference no longer occurs; update divergences.json")
        }
        if let pin {
            return actual == pin.actual
                ? ConformanceOutcome(status: pin.status, unexpected: false, detail: pin.note)
                : ConformanceOutcome(status: ConformanceStatus.fail.rawValue, unexpected: true, detail: "the result changed from the pinned difference")
        }
        return ConformanceOutcome(status: ConformanceStatus.fail.rawValue, unexpected: true, detail: "differs from the expected result and nothing in the corpus accounts for it")
    }
}
