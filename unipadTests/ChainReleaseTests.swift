import CryptoKit
import Foundation
import XCTest
@testable import unipad

/// Replays the approved, unchanged CR-001...006 inputs through the production screen model,
/// pack parser, and SoundEngine. These are playback IDs and pressed-light observations, not
/// physical fingers or a claim that the samples were heard. Only asynchronous checkpoints wait:
/// the simulator's real audio clock cannot provide the corpus's exact virtual millisecond clock.
/// Real finite-completion callbacks are held until their corpus checkpoint: a slow observation
/// must not consume a later checkpoint's completion. Playback timing is not measured here.
@MainActor
final class ChainReleaseTests: XCTestCase {
    private struct Corpus: Decodable { let cases: [Case] }
    private struct Case: Decodable { let id: String; let pack: String; let steps: [Step] }
    private struct Step: Decodable { let atMs: Int; let input: Input; let expected: Expected }
    private struct Input: Decodable { let kind: String; let inputId: String?; let pad: [Int]?; let chain: Int? }
    private struct Expected: Decodable {
        let chain: Int
        let starts: [Start]
        let releaseStops: [String]
        let naturalEnds: [String]
        let active: [String]
        let pressedInputs: [String]
    }
    private struct Start: Decodable {
        let playbackId: String; let inputId: String; let chain: Int; let pad: [Int]; let file: String
        let plays: Plays
    }
    private enum Plays: Decodable {
        case infinite, finite(Int)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Int.self) { self = .finite(number) }
            else {
                let text = try value.decode(String.self)
                guard text == "infinite" else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "unknown play count") }
                self = .infinite
            }
        }
        var loop: Int { switch self { case .infinite: -1; case .finite(let total): total - 1 } }
    }
    nonisolated private final class SelectionPack: UniPackFolder {
        struct Selection { let chain: Int; let x: Int; let y: Int; let file: String; let loop: Int }
        private let lock = NSLock()
        private var selections: [Selection] = []
        var started: [Selection] { lock.withLock { selections } }
        override func soundPush(c: Int, x: Int, y: Int) {
            if let sound = super.soundGet(c: c, x: x, y: y) {
                lock.withLock { selections.append(Selection(chain: c, x: x, y: y, file: sound.file.lastPathComponent, loop: sound.loop)) }
            }
            super.soundPush(c: c, x: x, y: y)
        }
    }

    private func resource(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    private func corpus() throws -> Corpus {
        try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: resource("expectations", "json")))
    }
    private func wait(_ reason: String, until ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(120)
        while !ready() {
            guard Date() < deadline else {
                XCTFail("\(reason): no result within 120 s")
                throw NSError(domain: "ChainReleaseTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func testApprovedFixtureBytesMatchSourceRevision() throws {
        let expected = [
            "expectations.json": "3aa66349d27c751938e6f86267b5ad0ac653828288d25a3777b7c4f0fbdf7fe0",
            "manual.uni": "31b158622efea7d779b673ecea3c72906c3764a7fbae16408060eb4e0f50931d",
            "delayed.uni": "7f8647fc894b4226df180061d94febaa9306c0a2c1a3d019299b47a6c56c7236"
        ]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: resource("manifest", "json"))) as! [String: Any]
        let files = try XCTUnwrap(manifest["files"] as? [String: [String: Any]])
        for (name, digest) in expected {
            let url = try resource((name as NSString).deletingPathExtension, (name as NSString).pathExtension)
            let actual = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(actual, digest, name)
            XCTAssertEqual(files[name.hasSuffix(".uni") ? "packs/\(name)" : name]?["sha256"] as? String, digest)
        }
        XCTAssertEqual(try corpus().cases.map(\.id), (1...6).map { String(format: "CR-%03d", $0) })
    }

    func testCR001ManualChainChangeStopsOnlyOriginalLoop() async throws { try await replay("CR-001") }
    func testCR002PackDelayedChainChangeStopsOnlyOriginalLoop() async throws { try await replay("CR-002") }
    func testCR003ReleasingOnePadPreservesOtherSoundAndLight() async throws { try await replay("CR-003") }
    func testCR004CancelDuplicateReleaseAndRepress() async throws { try await replay("CR-004") }
    func testCR005FinitePlaybackAndSoundSequence() async throws { try await replay("CR-005") }
    func testCR005FinitePlaybackWithDelayedObservation() async throws {
        try await replay("CR-005", observationDelay: .milliseconds(400))
    }
    func testCR006UnchangedChainPressAndRelease() async throws { try await replay("CR-006") }

    private func replay(_ id: String, observationDelay: Duration = .zero) async throws {
        let scenario = try XCTUnwrap(corpus().cases.first { $0.id == id })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChainRelease-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.unzipItem(at: resource(scenario.pack, "uni"), to: root)
        let pack = SelectionPack(rootFolder: root)
        let vm = PlayViewModel()
        vm.makePack = { _ in pack }
        try await vm.loadUnipack(path: root.path)
        defer { vm.cleanup() }
        try await wait("pack load", until: { vm.startReady || vm.unipackLoadError != nil || vm.quitRequested })
        XCTAssertTrue(vm.startReady, vm.unipackLoadError ?? "pack did not become ready")
        let engine = try XCTUnwrap(vm.soundEngine)
        var completions: [Int: () -> Void] = [:]
        engine.playbackCompletionDelivery = { playID, failure, complete in
            XCTAssertNil(failure, "finite playback failed instead of completing")
            completions[playID] = complete
        }
        defer { engine.playbackCompletionDelivery = nil }
        var inputs: [String: (x: Int, y: Int, id: UUID)] = [:]
        var playIDs: [String: Int] = [:]
        for step in scenario.steps {
            let label = "\(id) at \(step.atMs) ms \(step.input.kind)"
            let before = engine.activePlayIDs
            let selectionsBefore = pack.started.count
            switch step.input.kind {
            case "press":
                let name = try XCTUnwrap(step.input.inputId)
                let pad = try XCTUnwrap(step.input.pad)
                let input = (x: pad[0] - 1, y: pad[1] - 1, id: UUID())
                inputs[name] = input
                vm.padTouch(x: input.x, y: input.y, isDown: true, inputID: input.id)
            case "chain-button": vm.selectChain(try XCTUnwrap(step.input.chain) - 1)
            case "release", "cancel":
                let input = try XCTUnwrap(inputs[try XCTUnwrap(step.input.inputId)])
                vm.padTouch(x: input.x, y: input.y, isDown: false, inputID: input.id)
            case "checkpoint":
                if observationDelay != .zero { try await Task.sleep(for: observationDelay) }
                if scenario.pack == "delayed", step.atMs >= 100 {
                    try await wait("100 ms pack chain change", until: { vm.chain.value == step.expected.chain - 1 })
                }
                let endingIDs = Set(step.expected.naturalEnds.compactMap { playIDs[$0] })
                if !endingIDs.isEmpty {
                    try await wait("finite playback completion", until: { endingIDs.allSatisfy { completions[$0] != nil } })
                    for playID in endingIDs {
                        let complete = try XCTUnwrap(completions.removeValue(forKey: playID))
                        complete()
                    }
                }
            default: XCTFail("unsupported input \(step.input.kind)")
            }
            let after = engine.activePlayIDs
            let newIDs = after.subtracting(before)
            XCTAssertEqual(newIDs.count, step.expected.starts.count, label)
            XCTAssertEqual(pack.started.count - selectionsBefore, step.expected.starts.count, label)
            for start in step.expected.starts {
                playIDs[start.playbackId] = try XCTUnwrap(newIDs.first)
                let selected = try XCTUnwrap(pack.started.last)
                XCTAssertEqual(selected.file, (start.file as NSString).lastPathComponent, label)
                XCTAssertEqual(selected.loop, start.plays.loop, label)
                XCTAssertEqual(selected.chain, start.chain - 1, label)
                XCTAssertEqual([selected.x + 1, selected.y + 1], start.pad, label)
            }
            let ended = before.subtracting(after)
            let expectedEnded = Set((step.expected.releaseStops + step.expected.naturalEnds).compactMap { playIDs[$0] })
            XCTAssertEqual(ended, expectedEnded, label)
            XCTAssertEqual(after, Set(step.expected.active.compactMap { playIDs[$0] }), label)
            XCTAssertEqual(vm.chain.value, step.expected.chain - 1, label)
            let pressedPads = Set(step.expected.pressedInputs.compactMap { inputs[$0] }.map { $0.x * pack.buttonY + $0.y })
            for input in inputs.values {
                XCTAssertEqual(vm.padItems[input.x][input.y]?.channel == .pressed,
                               pressedPads.contains(input.x * pack.buttonY + input.y), label)
            }
            print("CHAIN-RELEASE \(label) active=\(after.sorted()) stopped=\(ended.sorted()) chain=\(vm.chain.value + 1)")
        }
    }
}
