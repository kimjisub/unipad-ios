import Foundation

nonisolated struct AutoPlay {
    var elements: [Element]
    /// Valid file commands before scheduled switches split waits. Mapping rewrites these commands,
    /// so it must not turn a sound's derived switch into an explicit, cancelling chain command.
    var sourceElements: [Element]? = nil

    enum Element {
        case on(x: Int, y: Int, currChain: Int, num: Int)
        case off(x: Int, y: Int, currChain: Int)
        case chain(c: Int)
        case delay(delay: Int)
    }
}
