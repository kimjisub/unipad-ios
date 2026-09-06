import Testing
@testable import unipad

struct TraceLogTextTests {
    @Test func emptySequenceHasNoLabels() {
        #expect(TraceLogText.perPad([], columns: 8, rows: 8).isEmpty)
    }

    @Test func tapsAreNumberedFromOneAndRepeatedPadsAccumulate() {
        let labels = TraceLogText.perPad([(x: 0, y: 0), (x: 1, y: 2), (x: 0, y: 0), (x: 1, y: 1)], columns: 3, rows: 2)
        #expect(labels[0] == "1 3")
        #expect(labels[1 * 3 + 2] == "2")
        #expect(labels[1 * 3 + 1] == "4")
        #expect(labels[1] == nil)
    }

    @Test func tapsOutsideTheGridAreIgnoredButStillCounted() {
        let labels = TraceLogText.perPad([(x: 5, y: 5), (x: 0, y: 0), (x: 0, y: 2), (x: -1, y: 0)], columns: 2, rows: 2)
        #expect(labels == [0: "2"])
    }
}
