import Foundation
import Testing
@testable import unipad

/// Both press commands use song time for wormholes, including a touch's immediate release.
struct AutoPlayTouchWormholeTests {
    private func parse(keySound: String, autoPlay: String, source: Bool = false) throws -> [String] {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AutoPlayTouchWormholeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let sounds = root.appending(path: "sounds", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        try Data("title=t\nproducerName=p\nbuttonX=8\nbuttonY=8\nchain=2\n".utf8).write(to: root.appending(path: "info"))
        try Data(keySound.utf8).write(to: root.appending(path: "keySound"))
        try Data(autoPlay.utf8).write(to: root.appending(path: "autoPlay"))
        for name in ["a.wav", "b.wav", "c.wav"] {
            try Data("sound".utf8).write(to: sounds.appending(path: name))
        }

        let pack = UniPackFolder(rootFolder: root)
        pack.load()
        pack.loadDetail()
        let timeline = try #require(pack.autoPlayTable)
        let elements = source ? try #require(timeline.sourceElements) : timeline.elements
        return elements.map {
            switch $0 {
            case .on(let x, let y, let c, let num): "on \(c) \(x) \(y) #\(num)"
            case .off(let x, let y, let c): "off \(c) \(x) \(y)"
            case .chain(let c): "chain \(c)"
            case .delay(let d): "delay \(d)"
            }
        }
    }

    private let keySound = """
    1 1 1 a.wav 1 2
    1 1 1 b.wav
    2 1 1 c.wav
    2 1 1 b.wav

    """

    @Test func touchFollowsTheWormholeLikeOn() throws {
        let touched = try parse(keySound: keySound, autoPlay: "t 1 1\nd 10\nt 1 1\n")
        #expect(touched == [
            "on 0 0 0 #0", "off 0 0 0", "delay 10",
            "on 0 0 0 #1", "off 0 0 0", "chain 1",
        ])

        let pressed = try parse(keySound: keySound, autoPlay: "o 1 1\nf 1 1\nd 10\no 1 1\nf 1 1\n")
        #expect(pressed.filter { !$0.hasPrefix("off") } == touched.filter { !$0.hasPrefix("off") })
    }

    @Test func touchWithoutAWormholeStaysOnItsChain() throws {
        let touched = try parse(keySound: "1 1 1 a.wav\n1 1 1 b.wav\n", autoPlay: "t 1 1\nt 1 1\n")
        #expect(touched == ["on 0 0 0 #0", "off 0 0 0", "on 0 0 0 #1", "off 0 0 0"])
    }

    @Test(arguments: [99, 100]) func pressAtTheDeadlineUsesTheDestination(delay: Int) throws {
        let result = try parse(keySound: keySound, autoPlay: "on 1 1\nd \(delay)\nt 1 1\n")
        let expected = delay == 99
            ? ["on 0 0 0 #0", "delay 99", "on 0 0 0 #1", "off 0 0 0", "chain 1"]
            : ["on 0 0 0 #0", "delay 100", "chain 1", "on 1 0 0 #0", "off 1 0 0"]
        #expect(result == expected)
    }

    @Test func aDelayIsSplitWithoutExtendingTheSong() throws {
        #expect(try parse(keySound: keySound, autoPlay: "on 1 1\nd 250\n") == [
            "on 0 0 0 #0", "delay 100", "chain 1", "delay 150",
        ])
    }

    @Test func anExplicitChainCancelsPendingSwitches() throws {
        #expect(try parse(keySound: keySound, autoPlay: "on 1 1\nd 50\nc 1\nd 200\n") == [
            "on 0 0 0 #0", "delay 50", "chain 0", "delay 200",
        ])
    }

    @Test func simultaneousSwitchesKeepPressOrderAndResetQueuesOnlyWhenApplied() throws {
        #expect(try parse(keySound: "1 1 1 a.wav 1 2\n1 1 1 b.wav 1 1\n", autoPlay: "on 1 1\non 1 1\nd 100\non 1 1\n") == [
            "on 0 0 0 #0", "on 0 0 0 #1", "delay 100", "chain 1", "chain 0",
            "on 0 0 0 #0", "chain 1",
        ])
    }

    @Test(arguments: [true, false]) func anEarlyPadNeverBringsTheSwitchForward(mapped: Bool) throws {
        let mapping = "1 1 1 a.wav 1 2\n2 1 2 c.wav\n" + (mapped ? "1 1 2 b.wav\n" : "")
        #expect(try parse(keySound: mapping, autoPlay: "on 1 1\nd 1\nt 1 2\nd 199\n") == [
            "on 0 0 0 #0", "delay 1", "on 0 0 1 #0", "off 0 0 1",
            "delay 99", "chain 1", "delay 100",
        ])
    }

    @Test func invalidLinesAndUnmappedPadsDoNotChangeDeadlines() throws {
        #expect(try parse(keySound: keySound, autoPlay: "on 1 1\nd 50\non 99 99\ninvalid\nt 2 2\nd 50\non 1 1\n") == [
            "on 0 0 0 #0", "delay 50", "on 0 1 1 #0", "off 0 1 1",
            "delay 50", "chain 1", "on 1 0 0 #0",
        ])
    }

    @Test(arguments: [1, 2]) func queuedVoiceSurvivesAShortGap(gap: Int) throws {
        // Shift a late-song transition to time zero and prime the voice pad's second sound.
        let mapping = "1 1 1 a.wav 1 2\n1 1 2 b.wav\n1 1 2 c.wav\n2 1 2 a.wav\n"
        #expect(try parse(keySound: mapping, autoPlay: "t 1 2\nt 1 1\nd \(gap)\nt 1 2\nd 200\n") == [
            "on 0 0 1 #0", "off 0 0 1", "on 0 0 0 #0", "off 0 0 0",
            "delay \(gap)", "on 0 0 1 #1", "off 0 0 1", "delay \(100 - gap)",
            "chain 1", "delay \(100 + gap)",
        ])
    }

    @Test func mappingReadsFileCommandsWithoutDerivedSwitchesOrSplitWaits() throws {
        #expect(try parse(keySound: keySound, autoPlay: "on 1 1\nd 250\nc 2\nt 1 1\n", source: true) == [
            "on 0 0 0 #0", "delay 250", "chain 1", "on 1 0 0 #0", "off 1 0 0",
        ])
    }

    @Test func twoIdenticalPressesKeepBothEndOfFileSwitches() throws {
        #expect(try parse(keySound: "1 1 1 a.wav 1 2\n", autoPlay: "t 1 1\nt 1 1\n") == [
            "on 0 0 0 #0", "off 0 0 0", "on 0 0 0 #1", "off 0 0 0", "chain 1", "chain 1",
        ])
    }

    @Test func aChainAtTheDeadlineFollowsTheDueSwitch() throws {
        #expect(try parse(keySound: keySound, autoPlay: "on 1 1\nd 100\nc 1\non 1 1\n") == [
            "on 0 0 0 #0", "delay 100", "chain 1", "chain 0", "on 0 0 0 #0", "chain 1",
        ])
    }
}
