import Foundation
import Testing
@testable import unipad

/// Which stored sound path a name matches, independent of the disk the pack is on.
struct PackFileFinderIndexTests {
    @Test func ofSeveralCaseCandidatesTheFirstInUTF16OrderIsTaken() {
        let index = PackFileFinder.Index(paths: ["end.wav", "END.wav", "fx/b.wav", "FX/a.wav"])
        #expect(index.match("End.wav") == "END.wav")
        #expect(index.match("end.wav") == "end.wav")
        #expect(index.match("Fx/b.wav") == "fx/b.wav")
        #expect(index.match("fx/A.wav") == "FX/a.wav")
        #expect(index.match("fx") == nil)
    }

    /// Each fallback compares whole original names; of several candidates at one step the first in
    /// UTF-16 order is taken.
    @Test func eachFallbackTakesItsFirstCandidateInUTF16Order() {
        let index = PackFileFinder.Index(entries: [
            .init(name: "A\u{E9}.wav", stored: "first.wav"),
            .init(name: "ae\u{301}.wav", stored: "second.wav")
        ])
        #expect(index.match("ae\u{301}.wav") == "second.wav")
        #expect(index.match("a\u{E9}.wav") == "second.wav")
        #expect(index.match("Ae\u{301}.wav") == "first.wav")
        #expect(index.match("a\u{E9}.WAV") == "first.wav")
    }

    @Test func anExactSpellingWinsOverACanonicallyEquivalentOne() {
        let composed = "\u{E9}.wav"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        let index = PackFileFinder.Index(paths: [composed, decomposed])
        #expect(index.match(decomposed).map { Array($0.unicodeScalars) } == Array(decomposed.unicodeScalars))
        #expect(index.match(composed).map { Array($0.unicodeScalars) } == Array(composed.unicodeScalars))
    }

    /// A name equal to a stored one up to Unicode composition is found before one that also differs
    /// in letter case, even when the other comes first in UTF-16 order.
    @Test func aCanonicalMatchWinsOverACaseFoldedOne() {
        let upperDecomposed = "E\u{301}.wav"
        let lowerComposed = "\u{E9}.wav"
        let index = PackFileFinder.Index(paths: [upperDecomposed, lowerComposed])
        #expect(index.match("e\u{301}.wav").map { Array($0.unicodeScalars) } == Array(lowerComposed.unicodeScalars))
        #expect(index.match("\u{C9}.wav").map { Array($0.unicodeScalars) } == Array(upperDecomposed.unicodeScalars))
        #expect(index.match("fx/E\u{301}.wav") == nil)
    }

    @Test func aStoredPathFromMetadataCannotLeaveTheSoundFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SoundIndex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "sounds")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appending(path: "a.wav"))
        try Data([2]).write(to: root.appending(path: "outside.wav"))
        try Data(#"{"version":1,"entries":[{"name":"a.wav","stored":"../outside.wav"}]}"#.utf8)
            .write(to: directory.appending(path: ".unipad-sound-paths.json"))
        let selected = try #require(PackFileFinder().file("a.wav", in: directory))
        #expect(try Data(contentsOf: selected) == Data([1]))
    }
}
