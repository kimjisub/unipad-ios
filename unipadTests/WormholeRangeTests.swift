import Foundation
import Testing
@testable import unipad

/// The sixth keySound column moves to another chain after the sound plays. A chain the pack does
/// not have reached autoPlay as its current chain, and practice lit that chain's button: from chain
/// 29 on the index ran past the round button table and the app closed, below that practice waited
/// for a chain nobody could select.
@MainActor
struct WormholeRangeTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let column: String
        let wormhole: Int
        let warns: Bool
        var testDescription: String { "wormhole \(column)" }
    }

    private static let chains = 4

    nonisolated static let cases: [Case] = [
        Case(column: "5", wormhole: 3, warns: true),
        Case(column: "40", wormhole: 3, warns: true),
        Case(column: "-2", wormhole: 0, warns: true),
        Case(column: "2", wormhole: 1, warns: false),
        Case(column: "0", wormhole: Sound.noWormhole, warns: false),
    ]

    @Test(arguments: cases)
    func movesToTheNearestChainThePackHas(_ sample: Case) throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "WormholeRangeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try PlayUsageScenario.writePack(to: root, keySound: "1 1 1 a.wav 1 \(sample.column)\n", autoPlay: "o 1 1\no 1 2\n")
        try "title=Wormhole\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=\(Self.chains)\n"
            .write(to: root.appending(path: "info"), atomically: true, encoding: .utf8)

        let pack = UniPackFolder(rootFolder: root)
        pack.checkFile()
        pack.loadInfo()
        pack.loadDetail()

        #expect(!pack.criticalError)
        let sound = try #require(pack.soundGet(c: 0, x: 0, y: 0))
        #expect(sound.wormhole == sample.wormhole, "the sound must stay, with its move inside the pack")
        let warning = "keySound : [1 1 1 a.wav 1 \(sample.column)] wormhole is incorrect"
        #expect(pack.errorDetail == (sample.warns ? warning : nil))

        let currentChains = try #require(pack.autoPlayTable).elements.compactMap { element -> Int? in
            if case .on(_, _, let chain, _) = element { return chain }
            return nil
        }
        #expect(currentChains.allSatisfy { (0..<Self.chains).contains($0) })
    }
}

extension PlayUsageRecordTests {
    /// The fixture pack has one chain, so a move to chain 2 or 40 lands back on chain 1.
    @MainActor
    struct WormholePracticeTests {
        private static func keySound(_ column: String) -> String { "1 1 1 a.wav 1 \(column)\n1 1 2 a.wav\n" }
        private static let autoPlay = "on 1 1\ndelay 100\non 1 2\n"

        @Test(arguments: ["2", "40"])
        func stepPracticeReachesTheEndAfterAMoveToAMissingChain(_ column: String) async throws {
            try await PlayUsageScenario.run(keySound: Self.keySound(column), autoPlay: Self.autoPlay) { s in
                try await s.loadReady()
                #expect(s.vm.unipackWarning == "keySound : [1 1 1 a.wav 1 \(column)] wormhole is incorrect")
                let runner = try #require(s.vm.autoPlayRunner)
                s.vm.switchPlayMode(.stepPractice)
                try await s.waitWhile { s.vm.padItems[0][0]?.channel != .guide }
                try #require(s.vm.padItems[0][0]?.channel == .guide, "the first step was not shown")
                s.press(0, 0)
                s.release(0, 0)
                try await s.waitWhile { s.vm.padItems[0][1]?.channel != .guide }
                try #require(s.vm.padItems[0][1]?.channel == .guide, "step practice stopped at the chain move")
                s.press(0, 1)
                s.release(0, 1)
                try await s.waitWhile { runner.active }
                #expect(!runner.active, "step practice did not reach the end")
                #expect(s.vm.chain.value == 0)
            }
        }

        @Test(arguments: ["2", "40"])
        func guidePlayReachesTheEndAfterAMoveToAMissingChain(_ column: String) async throws {
            try await PlayUsageScenario.run(keySound: Self.keySound(column), autoPlay: Self.autoPlay) { s in
                try await s.loadReady()
                let runner = try #require(s.vm.autoPlayRunner)
                s.vm.switchPlayMode(.guidePlay)
                try await s.waitWhile { s.vm.padGuideTargets[0][1] == 0 && runner.active }
                #expect(s.vm.padGuideTargets[0][1] > 0, "the guide did not show the pad after the chain move")
                try await s.autoplayEnded()
                #expect(!runner.active)
                #expect(s.vm.chain.value == 0)
            }
        }
    }
}
