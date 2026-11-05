import Testing
@testable import unipad

/// The stored keySound loop value (written value minus one) and how the engine schedules it.
struct SoundRepeatTests {
    @Test(arguments: [
        (-1, SoundRepeat.endless),
        (0, .plays(1)),
        (1, .plays(2)),
        (2, .plays(3)),
        (-2, .plays(1)),
        (Int(Int32.min) - 1, .plays(1)),
    ])
    func storedLoopValuesMapToTheirSchedule(stored: Int, expected: SoundRepeat) {
        #expect(SoundRepeat(storedLoop: stored) == expected)
    }
}
