import Foundation

final class LaunchpadProDriver: LaunchpadProgrammerDriver {
    override func getInitSysEx() -> (messages: [[UInt8]], cableNumber: Int)? {
        // Launchpad Pro (original): Live/Ableton mode + Session layout + Clear mode light
        return (messages: [
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x21, 0x00, 0xF7],
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x22, 0x00, 0xF7],
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0B, 0x63, 0x00, 0x00, 0x00, 0xF7]
        ], cableNumber: 0)
    }

    override func initialize() {
        guard let initData = getInitSysEx() else { return }
        for cable in 0...1 {
            sendRawSignals(messages: initData.messages, cableNumber: cable)
        }
    }

    /// Stock firmware lights the mode light with SysEx: velocity 0 turns it off, any other is a palette index.
    override func sendLogoLed(velocity: Int) {
        let level = Self.midiDataByte(velocity)
        if level == 0 {
            sendRawSignal(bytes: [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0B, 0x63, 0x00, 0x00, 0x00, 0xF7])
            sendRawSignal(bytes: [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0A, 0x63, 0x00, 0xF7])
        } else {
            sendRawSignal(bytes: [0xF0, 0x00, 0x20, 0x29, 0x02, 0x10, 0x0A, 0x63, level, 0xF7])
        }
    }
}
