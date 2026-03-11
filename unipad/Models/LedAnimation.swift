import Foundation

struct LedAnimation {
    static let defaultVelocity = 4

    let ledEvents: [LedEvent]
    let loop: Int
    let num: Int

    enum LedEvent {
        case on(x: Int, y: Int, color: Int = -1, velocity: Int = defaultVelocity)
        case off(x: Int, y: Int)
        case delay(delay: Int)
        case chain(chain: Int)
    }
}
