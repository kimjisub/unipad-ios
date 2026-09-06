import Foundation

/// Text for the classic trace log, where each pad shows the order of every tap on it.
enum TraceLogText {
    /// Returns, per pad key (`x * columns + y`), the 1-based index of every tap on that pad
    /// joined by spaces ("1 5"), which is the format the pre-4.1 trace log used.
    /// Pads that were never tapped are absent.
    static func perPad(_ sequence: [(x: Int, y: Int)], columns: Int) -> [Int: String] {
        var labels: [Int: String] = [:]
        for (index, point) in sequence.enumerated() {
            let key = point.x * columns + point.y
            if let existing = labels[key] {
                labels[key] = existing + " \(index + 1)"
            } else {
                labels[key] = "\(index + 1)"
            }
        }
        return labels
    }
}
