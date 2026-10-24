import Foundation

class LaunchpadXDriver: LaunchpadProgrammerDriver {
    override func getInitSysEx() -> (messages: [[UInt8]], cableNumber: Int)? {
        // Launchpad X: Standalone mode + Programmer mode via DAW port
        return (messages: [
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x10, 0x00, 0xF7],
            [0xF0, 0x00, 0x20, 0x29, 0x02, 0x0C, 0x0E, 0x01, 0xF7],
        ], cableNumber: 1)
    }

    override func initialize() {
        guard let initData = getInitSysEx() else { return }
        sendRawSignals(messages: initData.messages, cableNumber: initData.cableNumber)
    }
}
