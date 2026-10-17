import Testing

struct LedTimingComparisonTests {
    private func command(_ ms: Double, _ code: Int, x: Int = 0) -> LedCommand {
        LedCommand(ms: ms, target: LedTarget(x: x, y: 0), code: code)
    }

    @Test func cutoffStillRejectsAMissingCommandInTheMiddle() {
        let expected = [command(0, 5), command(50, 7), command(100, 9)]
        let comparison = LedTimingComparison(expected: expected, arrived: [expected[0], expected[2]])
        #expect(comparison.missing == 1)
        #expect(comparison.hasUnexpectedDifferences(allowMissingTail: true))
    }

    @Test func cutoffStillRejectsAMissingLedBeforeAnotherLedContinues() {
        let expected = [command(0, 5), command(50, 7, x: 1), command(100, 9)]
        let comparison = LedTimingComparison(expected: expected, arrived: [expected[0], expected[2]])
        #expect(comparison.hasUnexpectedDifferences(allowMissingTail: true))
    }

    @Test func onlyTheUnobservedTailIsAllowedAtACutoff() {
        let expected = [command(0, 5), command(50, 7), command(100, 9)]
        let comparison = LedTimingComparison(expected: expected, arrived: Array(expected.prefix(2)))
        #expect(!comparison.hasUnexpectedDifferences(allowMissingTail: true))
        #expect(comparison.hasUnexpectedDifferences(allowMissingTail: false))
    }

    @Test func cutoffStillRejectsReorderedOrExtraCommands() {
        let expected = [command(0, 5), command(50, 7)]
        let reordered = LedTimingComparison(expected: expected, arrived: expected.reversed())
        let extra = LedTimingComparison(expected: expected, arrived: expected + [command(100, 9)])
        #expect(reordered.hasUnexpectedDifferences(allowMissingTail: true))
        #expect(extra.hasUnexpectedDifferences(allowMissingTail: true))
    }
}
