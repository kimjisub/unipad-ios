import Foundation
import Testing
@testable import unipad

/// `touch` is `on` and `off` in one line, so touching a pad whose sound has a wormhole moves the
/// song to that chain exactly as `on` does, and the next press counts from the start of that chain.
struct AutoPlayTouchWormholeTests {
    private func parse(keySound: String, autoPlay: String) throws -> [String] {
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
        let elements = try #require(pack.autoPlayTable).elements
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
            "on 0 0 0 #0", "off 0 0 0", "chain 1",
            "delay 10",
            "on 1 0 0 #0", "off 1 0 0",
        ])

        let pressed = try parse(keySound: keySound, autoPlay: "o 1 1\nf 1 1\nd 10\no 1 1\nf 1 1\n")
        #expect(pressed.filter { !$0.hasPrefix("off") } == touched.filter { !$0.hasPrefix("off") })
    }

    @Test func touchWithoutAWormholeStaysOnItsChain() throws {
        let touched = try parse(keySound: "1 1 1 a.wav\n1 1 1 b.wav\n", autoPlay: "t 1 1\nt 1 1\n")
        #expect(touched == ["on 0 0 0 #0", "off 0 0 0", "on 0 0 0 #1", "off 0 0 0"])
    }
}
