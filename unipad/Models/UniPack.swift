import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "UniPack")

class UniPack: Equatable, Hashable {
    private var errors: [String] = []
    var errorDetail: String? {
        errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
    var criticalError = false

    var id: String { fatalError("Subclasses must override id") }

    var title = ""
    var producerName = ""
    var buttonX = 0
    var buttonY = 0
    var chain = 0
    var squareButton = true
    var website: String?

    var soundCount = 0
    var ledTableCount = 0

    // 3D tables: [chain][x][y], each cell is a circular queue (Deque)
    var soundTable: [[[Deque<Sound>?]]]?
    var ledAnimationTable: [[[Deque<LedAnimation>?]]]?
    var autoPlayTable: AutoPlay?

    var keyLedExist: Bool { false }
    var autoPlayExist: Bool { false }

    func lastModified() -> TimeInterval { fatalError("Subclasses must override") }

    var detailLoaded = false
    func loadInfo() -> UniPack { fatalError("Subclasses must override") }
    func loadDetail() -> UniPack { fatalError("Subclasses must override") }

    func loadDetailWithProgress(onPhase: (String, Int, Int) -> Void) -> UniPack {
        return loadDetail()
    }

    func checkFile() { fatalError("Subclasses must override") }
    func delete() { fatalError("Subclasses must override") }
    func getPathString() -> String { fatalError("Subclasses must override") }
    func getByteSize() -> Int64 { fatalError("Subclasses must override") }

    private(set) var loaded = false
    @discardableResult
    func load() -> UniPack {
        if !loaded {
            checkFile()
        }
        loadInfo()
        loaded = true
        return self
    }

    // MARK: - Circular Queue Operations

    func soundGet(c: Int, x: Int, y: Int) -> Sound? {
        guard let sounds = soundTable?[safe: c]?[safe: x]?[safe: y] ?? nil else { return nil }
        return sounds.first
    }

    func soundGet(c: Int, x: Int, y: Int, num: Int) -> Sound? {
        guard let sounds = soundTable?[safe: c]?[safe: x]?[safe: y] ?? nil else { return nil }
        guard !sounds.isEmpty else { return nil }
        return sounds[num % sounds.count]
    }

    func soundPush(c: Int, x: Int, y: Int) {
        guard var sounds = soundTable?[safe: c]?[safe: x]?[safe: y] ?? nil else { return }
        guard !sounds.isEmpty else { return }
        let item = sounds.removeFirst()
        sounds.append(item)
        soundTable?[c][x][y] = sounds
    }

    func soundPush(c: Int, x: Int, y: Int, num: Int) {
        guard var sounds = soundTable?[safe: c]?[safe: x]?[safe: y] ?? nil else { return }
        guard !sounds.isEmpty else { return }
        let targetNum = num % sounds.count
        guard sounds.first?.num != targetNum else { return }
        while true {
            let item = sounds.removeFirst()
            sounds.append(item)
            if sounds.first?.num == targetNum { break }
        }
        soundTable?[c][x][y] = sounds
    }

    func ledGet(c: Int, x: Int, y: Int) -> LedAnimation? {
        guard let leds = ledAnimationTable?[safe: c]?[safe: x]?[safe: y] ?? nil else { return nil }
        return leds.first
    }

    func ledPush(c: Int, x: Int, y: Int) {
        guard var leds = ledAnimationTable?[safe: c]?[safe: x]?[safe: y] ?? nil else { return }
        guard !leds.isEmpty else { return }
        let item = leds.removeFirst()
        leds.append(item)
        ledAnimationTable?[c][x][y] = leds
    }

    func ledPush(c: Int, x: Int, y: Int, num: Int) {
        guard var leds = ledAnimationTable?[safe: c]?[safe: x]?[safe: y] ?? nil else { return }
        guard !leds.isEmpty else { return }
        let targetNum = num % leds.count
        guard leds.first?.num != targetNum else { return }
        while true {
            let item = leds.removeFirst()
            leds.append(item)
            if leds.first?.num == targetNum { break }
        }
        ledAnimationTable?[c][x][y] = leds
    }

    // MARK: - Error Management

    func addErr(_ content: String) {
        errors.append(content)
        logger.error("\(content)")
    }

    func infoString() -> String {
        let sizeMB = String(format: "%.2f", Double(getByteSize()) / 1_048_576.0)
        return """
        Title : \(title)
        Producer : \(producerName)
        Pad Size : \(buttonX) x \(buttonY)
        Chain : \(chain)
        File Size : \(sizeMB) MB
        """
    }

    static func == (lhs: UniPack, rhs: UniPack) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var description: String { "UniPack(id=\(id))" }
}

// MARK: - Deque (value-type circular queue backed by Array)

struct Deque<Element>: Sequence {
    private var storage: [Element] = []

    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }
    var first: Element? { storage.first }

    subscript(index: Int) -> Element {
        get { storage[index] }
        set { storage[index] = newValue }
    }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    @discardableResult
    mutating func removeFirst() -> Element {
        storage.removeFirst()
    }

    func makeIterator() -> IndexingIterator<[Element]> {
        storage.makeIterator()
    }
}

// MARK: - Safe Array Subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
