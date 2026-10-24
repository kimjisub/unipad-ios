import XCTest
import CryptoKit
import AVFoundation
#if !ADMISSION_STANDALONE
@testable import unipad
#endif

/// The shared corpus pins structural admission, not decoded duration or device memory safety.
final class AudioAdmissionTests: XCTestCase {
    private var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/AudioSafety")
    }
    private func corpus() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("cases.json"))) as? [String: Any])
    }
    private func integer(_ value: Any?) -> Int {
        if let text = value as? String { return Int(text)! }
        return (value as! NSNumber).intValue
    }
    private func reason(_ value: Any?) -> AudioAdmission.Exclusion? {
        (value as? String).flatMap(AudioAdmission.Exclusion.init(rawValue:))
    }
    func testCommonCosts() throws {
        for c in try corpus()["costs"] as! [[String: Any]] {
            let result = AudioAdmission.cost(.init(sampleRate: integer(c["rate"]), channels: integer(c["channels"]), frames: integer(c["frames"])))
            XCTAssertEqual(result.exclusion, reason(c["exclusion"]), "\(c["id"]!)")
            XCTAssertEqual(result.cost, c["cost"].map { integer($0) } ?? 0, "\(c["id"]!)")
        }
    }
    func testCommonPhysicalFilesAndHashes() throws {
        let manifest = try Data(contentsOf: directory.appendingPathComponent("cases.json"))
        XCTAssertEqual(SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined(), "b16e4f635d671b3ab2d20222cea55bec72cce91e496d6b2ea87ccf6525c193c4")
        for c in try corpus()["files"] as! [[String: Any]] {
            let name = c["file"] as! String
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), c["sha256"] as? String, name)
            let result = AudioFileInspection.inspect(bytes)
            XCTAssertEqual(result.exclusion, reason(c["exclusion"]), name)
            if c["exclusion"] == nil {
                let facts = try XCTUnwrap(result.facts, name)
                XCTAssertEqual(facts.sampleRate, integer(c["rate"]), name)
                XCTAssertEqual(facts.channels, integer(c["channels"]), name)
                XCTAssertEqual(facts.frames, integer(c["frames"]), name)
            }
        }
    }
    private func wave(rate: Int, channels: Int, frames: Int, claimed: Int) -> Data {
        var b = Data()
        func text(_ s: String) { b.append(contentsOf: s.utf8) }
        func word(_ n: Int, _ width: Int) { for i in 0..<width { b.append(UInt8(truncatingIfNeeded: n >> (i * 8))) } }
        let size = frames * channels * 2
        text("RIFF"); word(48 + size, 4); text("WAVEfmt "); word(16, 4)
        word(1, 2); word(channels, 2); word(rate, 4); word(rate * channels * 2, 4)
        word(channels * 2, 2); word(16, 2); text("fact"); word(4, 4); word(claimed * rate, 4)
        text("data"); word(size, 4); b.append(Data(count: size))
        return b
    }
    func testCommonGeneratedWavesIgnoreClaimedDuration() throws {
        for c in try corpus()["wavRecipes"] as! [[String: Any]] {
            let id = c["id"] as! String
            let result = AudioFileInspection.inspect(wave(rate: integer(c["rate"]), channels: integer(c["channels"]), frames: integer(c["frames"]), claimed: integer(c["claimedSeconds"])))
            XCTAssertNil(result.exclusion, id)
            let facts = try XCTUnwrap(result.facts, id)
            XCTAssertEqual(facts.frames, integer(c["frames"]), id)
            let cost = AudioAdmission.cost(facts)
            XCTAssertEqual(cost.exclusion, reason(c["exclusion"]), id)
            XCTAssertEqual(cost.cost, integer(c["expectedCost"]), id)
        }
    }
    func testExistingNativePCMContainersRemainReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AudioAdmission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        for ext in ["caf", "aiff"] {
            let url = root.appendingPathComponent("silence." + ext)
            do { let file = try AVAudioFile(forWriting: url, settings: settings); try file.write(from: buffer) }
            let file = try AVAudioFile(forReading: url)
            let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800))
            try file.read(into: decoded)
            XCTAssertEqual(decoded.frameLength, 4800, ext)
            let expected = AudioAdmission.Facts(sampleRate: 48000, channels: 2, frames: 4800)
            XCTAssertEqual(AudioFileInspection.inspect(url: url).facts, expected, ext)
            var bytes = try Data(contentsOf: url)
            if ext == "caf" {
                let marker = try XCTUnwrap(bytes.range(of: Data("data".utf8)))
                bytes.replaceSubrange(marker.upperBound..<(marker.upperBound + 8), with: [UInt8](repeating: 255, count: 8))
                XCTAssertEqual(AudioFileInspection.inspect(bytes).facts, expected, "CAF data through EOF")
            } else {
                let comm = try XCTUnwrap(bytes.range(of: Data("COMM".utf8))).lowerBound
                bytes.replaceSubrange((comm + 10)..<(comm + 14), with: [0, 0, 0, 1])
                XCTAssertEqual(AudioFileInspection.inspect(bytes).facts, expected, "AIFF ignores stale frame claims")
                let sound = try XCTUnwrap(bytes.range(of: Data("SSND".utf8))).lowerBound
                for (codec, precision) in [("in24", 64), ("in32", 64), ("sowt", 32)] {
                    var mismatch = try Data(contentsOf: url)
                    mismatch.replaceSubrange((comm + 14)..<(comm + 16), with: [0, UInt8(precision)])
                    mismatch.replaceSubrange((comm + 26)..<(comm + 30), with: Data(codec.utf8))
                    XCTAssertEqual(AudioFileInspection.inspect(mismatch).exclusion, .invalidFormat, "AIFC fixed precision: \(codec)")
                }
                bytes.replaceSubrange((sound + 8)..<(sound + 12), with: [255, 255, 255, 255])
                XCTAssertEqual(AudioFileInspection.inspect(bytes).exclusion, .invalidFormat, "AIFF offset beyond data")
            }
        }
    }
    func testWaveMpegEncodingRejectsADTSPayload() throws {
        let aac = try Data(contentsOf: directory.appendingPathComponent("tone.aac"))
        var bytes = wave(rate: 44100, channels: 1, frames: 0, claimed: 0)
        bytes.replaceSubrange(20..<22, with: [85, 0])
        let size = aac.count
        for i in 0..<4 { bytes[52 + i] = UInt8(truncatingIfNeeded: size >> (i * 8)) }
        bytes.append(aac)
        XCTAssertEqual(AudioFileInspection.inspect(bytes).exclusion, .invalidFormat)
    }
    private func nativeFixture(_ name: String) -> URL {
        directory.deletingLastPathComponent().appendingPathComponent("NativeAudio").appendingPathComponent(name)
    }
    func testAIFFSoundChunkMayPrecedeCommonChunk() throws {
        let url = nativeFixture("ssnd-first.aiff")
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 13230))
        try file.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, 13230)
        XCTAssertEqual(AudioFileInspection.inspect(url: url).facts,
                       .init(sampleRate: 44100, channels: 1, frames: 13230))
    }
    func testKnownNativeDecoderFormatsRemainExplicitlyExcluded() throws {
        // These valid native-decoder inputs expose a coverage gap, not damaged audio.
        // Pin the current structural result until shared support is resolved before integration.
        for name in ["alaw.wav", "ulaw.wav", "aac.caf", "alac.caf", "ima4.caf", "ulaw.aifc"] {
            XCTAssertEqual(AudioFileInspection.inspect(url: nativeFixture(name)).exclusion, .invalidFormat, name)
        }
    }
    func testCommonSelectionKeepsReservationsAfterDecodeFailure() throws {
        for c in try corpus()["selections"] as! [[String: Any]] {
            let refs = (c["references"] as! [[Any]]).map { AudioAdmission.Reference(chain: integer($0[0]), x: integer($0[1]), y: integer($0[2]), line: integer($0[3]), identity: $0[4] as! String) }
            let bounds = c["bounds"] as! [Int]
            let facts = c["facts"] as! [String: Any]
            var calls = [String]()
            let plan = try AudioAdmission.select(refs, bounds: .init(chains: bounds[0], width: bounds[1], height: bounds[2])) { id in
                calls.append(id)
                guard let f = facts[id] as? [Any] else { return .rejected(.readFailure) }
                return .accepted(.init(sampleRate: self.integer(f[0]), channels: self.integer(f[1]), frames: self.integer(f[2])))
            }
            XCTAssertEqual(calls, c["order"] as! [String])
            XCTAssertEqual(plan.files.map(\.identity), calls)
            XCTAssertEqual(plan.files.map(\.exclusion), (c["exclusions"] as! [Any]).map { reason($0) })
            XCTAssertEqual(plan.files.filter { $0.exclusion == nil }.map(\.identity), c["selected"] as! [String])
            XCTAssertEqual(plan.reservedCost, integer(c["reservedCost"]))
            // Decode results are deliberately outside the immutable plan. Integration must
            // separately prove that a failed decoder cannot re-run admission or refund cost.
            let snapshot = plan
            for _ in plan.files.reversed() { _ = Result<Void, NSError>.failure(NSError(domain: "decode", code: 1)) }
            XCTAssertEqual(plan, snapshot)
        }
    }
    func testRemainingBudgetBoundaries() throws {
        for (rate, frames, accepted) in [(48000, 9508864, true), (48000, 9508865, false), (44100, 8736268, true), (44100, 8736269, false)] {
            let refs = (0..<3).map { AudioAdmission.Reference(chain: 0, x: 0, y: 0, line: $0, identity: String($0)) }
            let plan = try AudioAdmission.select(refs, bounds: .init(chains: 1, width: 1, height: 1)) { id in
                .accepted(.init(sampleRate: id == "2" ? rate : 48000, channels: 2, frames: id == "2" ? frames : 28800000))
            }
            XCTAssertEqual(plan.files[2].exclusion, accepted ? nil : .packLimit)
            XCTAssertEqual(plan.reservedCost, accepted ? 134217728 : 115200000)
        }
    }
    func testThrownReadFailureIsFinalForDuplicates() throws {
        var calls = [String]()
        let refs = ["bad", "bad", "good"].enumerated().map { AudioAdmission.Reference(chain: 0, x: 0, y: 0, line: $0.offset, identity: $0.element) }
        let plan = try AudioAdmission.select(refs, bounds: .init(chains: 1, width: 1, height: 1)) { id in
            calls.append(id)
            if id == "bad" { throw NSError(domain: "read", code: 1) }
            return .accepted(.init(sampleRate: 48000, channels: 2, frames: 1))
        }
        XCTAssertEqual(calls, ["bad", "good"])
        XCTAssertEqual(plan.files.map(\.exclusion), [.readFailure, nil])
        XCTAssertEqual(plan.reservedCost, 2)
    }
    func testNumericOrderBeforeDeduplication() throws {
        let refs: [AudioAdmission.Reference] = [
            .init(chain: 1, x: 0, y: 0, line: 0, identity: "chain"),
            .init(chain: 0, x: 1, y: 0, line: 0, identity: "x"),
            .init(chain: 0, x: 0, y: 1, line: 0, identity: "y"),
            .init(chain: 0, x: 0, y: 0, line: 2, identity: "line2"),
            .init(chain: 0, x: 0, y: 0, line: 1, identity: "first"),
            .init(chain: 2, x: 0, y: 0, line: 0, identity: "first"),
            .init(chain: 0, x: -1, y: 0, line: 0, identity: "outside"),
            .init(chain: 0, x: 0, y: 2, line: 0, identity: "outside"),
            .init(chain: 0, x: 0, y: 0, line: 3, identity: "line2")
        ]
        let plan = try AudioAdmission.select(refs, bounds: .init(chains: 2, width: 2, height: 2)) { _ in .accepted(.init(sampleRate: 48000, channels: 2, frames: 1)) }
        XCTAssertEqual(plan.files.map(\.identity), ["first", "line2", "y", "x", "chain"])
        XCTAssertEqual(plan.reservedCost, 10)
        XCTAssertThrowsError(try AudioAdmission.select([], bounds: .init(chains: -1, width: 1, height: 1)) { _ in .rejected(.readFailure) })
    }
    private func words(_ values: [Int]) -> Data {
        var d = Data()
        for value in values { for shift in [24, 16, 8, 0] { d.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        return d
    }
    private func box(_ type: String, _ parts: Data...) -> Data {
        let payload = parts.reduce(into: Data()) { $0.append($1) }
        return words([payload.count + 8]) + Data(type.utf8) + payload
    }
    private func pcmChunks(_ count: Int) -> Data {
        var entry = Data(count: 28)
        entry[7] = 1; entry[17] = 1; entry[19] = 16
        entry.replaceSubrange(24..<28, with: words([48000 << 16]))
        let stsd = box("stsd", words([0, 1]), box("sowt", entry))
        let offsets = words([0, count] + (0..<count).map { 8 + $0 * 2 })
        let stbl = box("stbl", stsd, box("stts", words([0, 1, count, 1])), box("stsz", words([0, 2, count])), box("stsc", words([0, 1, 1, 1, 1])), box("stco", offsets))
        let mdhd = box("mdhd", words([0, 0, 0, 48000, count]))
        let hdlr = box("hdlr", words([0, 0]), Data("soun".utf8))
        return box("mdat", Data(count: count * 2)) + box("moov", box("trak", box("mdia", mdhd, hdlr, box("minf", stbl))))
    }
    func testBoundedMP4TablesInspectEveryPhysicalFrame() throws {
        XCTAssertEqual(AudioFileInspection.inspect(pcmChunks(4096)).facts?.frames, 4096)
        XCTAssertEqual(AudioFileInspection.inspect(pcmChunks(262145)).exclusion, .readFailure)
        var manyBoxes = try Data(contentsOf: directory.appendingPathComponent("tone.m4a"))
        for _ in 0..<4097 { manyBoxes.append(box("free")) }
        XCTAssertEqual(AudioFileInspection.inspect(manyBoxes).exclusion, .readFailure)
    }
    func testMPEGProbeBudgetCannotReturnPartialAdmission() throws {
        var bytes = try Data(contentsOf: directory.appendingPathComponent("tone.mp3"))
        for _ in 0..<1024 { bytes.append(contentsOf: [255, 231, 232, 192, 0]) }
        XCTAssertEqual(AudioFileInspection.inspect(bytes).exclusion, .readFailure)
    }
    func testFileReadFailureAndIntegerOverflowAreSafe() throws {
        XCTAssertEqual(AudioFileInspection.inspect(url: directory.appendingPathComponent("missing")).exclusion, .readFailure)
        XCTAssertEqual(AudioFileInspection.inspect(Data()).exclusion, .invalidFormat)
        XCTAssertThrowsError(try AudioRead.add(.max, 1))
        XCTAssertThrowsError(try AudioRead.multiply(.max, 2))
        XCTAssertThrowsError(try AudioRead(Data(repeating: 255, count: 8)).uint(0, 8))
    }
}
