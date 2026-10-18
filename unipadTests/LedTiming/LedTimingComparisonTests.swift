import Testing

struct LedTimingComparisonTests {
    private func command(_ ms: Double, _ code: Int, x: Int = 0) -> LedCommand {
        LedCommand(ms: ms, target: LedTarget(x: x, y: 0), code: code)
    }

    @Test func cutoffStillRejectsAMissingCommandInTheMiddle() {
        let expected = [command(0, 5), command(50, 7), command(100, 9)]
        let comparison = LedTimingComparison(expected: expected, arrived: [expected[0], expected[2]])
        #expect(comparison.missing == 1)
        #expect(comparison.hasUnexpectedDifferences(cutoffMs: 150))
    }

    @Test func cutoffStillRejectsAMissingLedBeforeAnotherLedContinues() {
        let expected = [command(0, 5), command(50, 7, x: 1), command(100, 9)]
        let comparison = LedTimingComparison(expected: expected, arrived: [expected[0], expected[2]])
        #expect(comparison.hasUnexpectedDifferences(cutoffMs: 150))
    }

    @Test func onlyTheUnobservedTailIsAllowedAtACutoff() {
        let expected = [command(0, 5), command(50, 7), command(100, 9)]
        let comparison = LedTimingComparison(expected: expected, arrived: Array(expected.prefix(2)))
        #expect(!comparison.hasUnexpectedDifferences(cutoffMs: 150))
        #expect(comparison.hasUnexpectedDifferences(cutoffMs: nil))
    }

    @Test func cutoffRejectsAllOutputStoppingLongBeforeTheDeadline() {
        let expected = (0..<600).map { command(Double($0 * 50), $0 % 2 == 0 ? 5 : 7) }
        let comparison = LedTimingComparison(expected: expected, arrived: Array(expected.prefix(200)))
        #expect(comparison.missing == 400)
        #expect(comparison.unexpectedMissing(cutoffMs: 30_000) == 399)
        #expect(comparison.hasUnexpectedDifferences(cutoffMs: 30_000))
    }

    @Test func cutoffAllowsALateLedNearTheDeadlineEvenWhenAnotherLedContinues() {
        let expected = [command(0, 5), command(598, 7, x: 1), command(600, 9)]
        let comparison = LedTimingComparison(expected: expected, arrived: [expected[0], expected[2]])
        // The missing command can arrive after a 625 ms cutoff, despite another LED matching at 600 ms.
        #expect(!comparison.hasUnexpectedDifferences(cutoffMs: 625))
        #expect(comparison.hasUnexpectedDifferences(cutoffMs: nil))
    }

    @Test(arguments: [574.0, 575.0, 576.0])
    func cutoffWindowHasAFixedBoundary(missingTime: Double) {
        let expected = [command(0, 5), command(missingTime, 7)]
        let comparison = LedTimingComparison(expected: expected, arrived: [expected[0]])
        #expect(comparison.hasUnexpectedDifferences(cutoffMs: 625) == (missingTime < 575))
        #expect(comparison.hasUnexpectedDifferences(cutoffMs: nil))
    }

    @Test func cutoffStillRejectsReorderedOrExtraCommands() {
        let expected = [command(0, 5), command(50, 7)]
        let reordered = LedTimingComparison(expected: expected, arrived: expected.reversed())
        let extra = LedTimingComparison(expected: expected, arrived: expected + [command(100, 9)])
        #expect(reordered.hasUnexpectedDifferences(cutoffMs: 150))
        #expect(extra.hasUnexpectedDifferences(cutoffMs: 150))
    }
}
