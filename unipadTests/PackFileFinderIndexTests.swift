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

    @Test func anExactSpellingWinsOverACanonicallyEquivalentOne() {
        let composed = "\u{E9}.wav"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        let index = PackFileFinder.Index(paths: [composed, decomposed])
        #expect(index.match(decomposed).map { Array($0.unicodeScalars) } == Array(decomposed.unicodeScalars))
        #expect(index.match(composed).map { Array($0.unicodeScalars) } == Array(composed.unicodeScalars))
    }
}
