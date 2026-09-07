import Foundation

/// Current chain plus its observers. `value` is read from the AutoPlay and LED runner threads, so
/// the state lives behind a lock; observers are notified outside it, and callers that mutate UI
/// state must call setValue on the main thread (the runners hop there first).
final class ChainObserver {
    var range: ClosedRange<Int> = Int.min...Int.max

    private let lock = NSLock()
    private var _value: Int = 0
    private var observers: [(id: UUID, handler: (_ curr: Int, _ prev: Int) -> Void)] = []

    private(set) var value: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }

    func setValue(_ newValue: Int) {
        let clamped: Int
        if newValue < range.lowerBound {
            clamped = range.lowerBound
        } else if newValue > range.upperBound {
            clamped = range.upperBound
        } else {
            clamped = newValue
        }

        lock.lock()
        let prev = _value
        _value = clamped
        let snapshot = observers
        lock.unlock()
        for observer in snapshot {
            observer.handler(clamped, prev)
        }
    }

    func refresh(curr: Int? = nil, prev: Int? = nil) {
        lock.lock()
        let current = _value
        let snapshot = observers
        lock.unlock()
        for observer in snapshot {
            observer.handler(curr ?? current, prev ?? current)
        }
    }

    @discardableResult
    func addObserver(_ observer: @escaping (_ curr: Int, _ prev: Int) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers.append((id: id, handler: observer))
        lock.unlock()
        return id
    }

    func removeObserver(id: UUID) {
        lock.lock()
        observers.removeAll { $0.id == id }
        lock.unlock()
    }

    func clearObservers() {
        lock.lock()
        observers.removeAll()
        lock.unlock()
    }
}
