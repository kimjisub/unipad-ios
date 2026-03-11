import Foundation

final class ChainObserver {
    var range: ClosedRange<Int> = Int.min...Int.max

    private(set) var value: Int = 0

    private var observers: [(id: UUID, handler: (_ curr: Int, _ prev: Int) -> Void)] = []

    func setValue(_ newValue: Int) {
        let clamped: Int
        if newValue < range.lowerBound {
            clamped = range.lowerBound
        } else if newValue > range.upperBound {
            clamped = range.upperBound
        } else {
            clamped = newValue
        }

        let prev = value
        value = clamped
        notifyObservers(curr: value, prev: prev)
    }

    func refresh(curr: Int? = nil, prev: Int? = nil) {
        notifyObservers(curr: curr ?? value, prev: prev ?? value)
    }

    @discardableResult
    func addObserver(_ observer: @escaping (_ curr: Int, _ prev: Int) -> Void) -> UUID {
        let id = UUID()
        observers.append((id: id, handler: observer))
        return id
    }

    func removeObserver(id: UUID) {
        observers.removeAll { $0.id == id }
    }

    func clearObservers() {
        observers.removeAll()
    }

    private func notifyObservers(curr: Int, prev: Int) {
        for observer in observers {
            observer.handler(curr, prev)
        }
    }
}
