import Foundation

struct AutoPlay {
    var elements: [Element]

    enum Element {
        case on(x: Int, y: Int, currChain: Int, num: Int)
        case off(x: Int, y: Int, currChain: Int)
        case chain(c: Int)
        case delay(delay: Int)
    }
}
