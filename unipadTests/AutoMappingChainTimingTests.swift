import Foundation
import Testing
@testable import unipad

@MainActor
struct AutoMappingChainTimingTests {
    /// Different sounds on either side of the deadline expose both lengthening and shortening
    /// a wait. The first voice press also primes its queue before the sound that changes pages.
    @Test(arguments: [1, 99, 100, 250], [60, 500])
    func mappingKeepsTheParsedPageAndQueue(gap: Int, soundLength: Int) async throws {
        let pack = try Pack(
            keySound: "3 2 3 move.wav 1 4\n3 2 6 first.wav\n3 2 6 voice.wav\n4 2 6 drum.wav\n",
            autoPlay: "c 3\nt 2 6\non 2 3\nd \(gap)\nt 2 6\nd 199\n")
        defer { pack.remove() }
        let original = try pack.presses()
        #expect(original.last == (gap < 100 ? "2:1:5:1:voice.wav" : "3:1:5:0:drum.wav"))

        try await pack.map(lengths: ["move.wav": soundLength])

        #expect((try pack.presses()) == original)
        let wait = gap <= 100 ? gap : max(100, soundLength)
        #expect((try pack.pressTimes()) == [1000, 1000, 1000 + wait])
        // Reopening and mapping again must not move the press across the same deadline either.
        try await pack.map(lengths: ["move.wav": soundLength])
        #expect((try pack.presses()) == original)
    }

    @Test(arguments: [
        "on 1 1\nd 30\non 1 2\nd 20\nt 1 3\nd 100\nt 1 3\n",
        "on 1 1\non 1 2\nd 150\nt 1 3\n",
        "on 1 1\nd 30\nc 2\nd 20\nt 1 3\n",
        "on 1 1\nd 50\nc 1\nd 200\nt 1 3\n",
    ])
    func mappingKeepsOverlappingAndCancelledMoves(autoPlay: String) async throws {
        let pack = try Pack(
            keySound: "1 1 1 move.wav 1 2\n1 1 2 other.wav 1 3\n1 1 3 voice.wav\n2 1 3 drum.wav\n3 1 3 first.wav\n",
            autoPlay: autoPlay)
        defer { pack.remove() }
        let original = try pack.presses()

        try await pack.map(lengths: ["move.wav": 500, "other.wav": 10, "voice.wav": 500])

        #expect((try pack.presses()) == original)
    }

    /// Rewinding song time while a move is pending must survive the rewrite, with or
    /// without a readable sound length, so the next press still uses the original page.
    @Test(arguments: [false, true])
    func mappingKeepsNegativeWaitsBeforeAPendingMove(knownLength: Bool) async throws {
        let pack = try Pack(
            keySound: "1 1 1 move.wav 1 2\n1 1 2 voice.wav\n2 1 2 drum.wav\n",
            autoPlay: "on 1 1\nd -50\nd 120\nt 1 2\n")
        defer { pack.remove() }
        let original = try pack.presses()
        #expect(original.last == "0:0:1:0:voice.wav")
        #expect((try pack.pressTimes()) == [0, 70])

        for _ in 0..<2 {
            try await pack.map(lengths: knownLength ? ["move.wav": 500] : [:])
            #expect((try pack.presses()) == original)
            #expect((try pack.pressTimes()) == [1000, 1070])
        }
    }

    private final class Listener: UniPackAutoMapperListener {
        var error: Error?
        var done = false
        func onStart() {}
        func onGetWorkSize(_ size: Int) {}
        func onProgress(_ progress: Int) {}
        func onDone() { done = true }
        func onException(_ error: Error) { self.error = error }
    }

    @MainActor
    private struct Pack {
        let root: URL

        init(keySound: String, autoPlay: String) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "MapperTiming-\(UUID().uuidString)")
            let sounds = root.appending(path: "sounds")
            try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
            try "title=Timing\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=4\n".write(to: root.appending(path: "info"), atomically: true, encoding: .utf8)
            try keySound.write(to: root.appending(path: "keySound"), atomically: true, encoding: .utf8)
            try autoPlay.write(to: root.appending(path: "autoPlay"), atomically: true, encoding: .utf8)
            for name in ["move.wav", "other.wav", "first.wav", "voice.wav", "drum.wav"] {
                try Data("sound".utf8).write(to: sounds.appending(path: name))
            }
        }

        func open() -> UniPackFolder {
            let pack = UniPackFolder(rootFolder: root)
            pack.load()
            pack.loadDetail()
            return pack
        }

        func presses() throws -> [String] {
            let pack = open()
            return try #require(pack.autoPlayTable).elements.compactMap { element in
                guard case .on(let x, let y, let chain, let num) = element else { return nil }
                let name = pack.soundGet(c: chain, x: x, y: y, num: num)?.file.lastPathComponent ?? "silent"
                return "\(chain):\(x):\(y):\(num):\(name)"
            }
        }

        func map(lengths: [String: Int]) async throws {
            let listener = Listener()
            await UniPackAutoMapper(unipack: open(), listener: listener, soundLength: { url in
                lengths[url.lastPathComponent].map(Double.init)
            }).start().value
            if let error = listener.error { throw error }
            #expect(listener.done)
        }

        func pressTimes() throws -> [Int] {
            var time = 0
            return try #require(open().autoPlayTable).elements.compactMap { element in
                switch element {
                case .delay(let delay): time += delay; return nil
                case .on: return time
                default: return nil
                }
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
