import Foundation

final class ChannelManager {
    static let circularButtonCount = 36

    enum Channel: Int, CaseIterable {
        case ui = 0
        case uiUnipad = 1
        case guide = 2
        case pressed = 3
        case chain = 4
        case led = 5

        /// Priority index used for array storage.
        /// PRESSED and CHAIN share the same priority (matching Android behavior).
        var priority: Int {
            switch self {
            case .ui: 0
            case .uiUnipad: 1
            case .guide: 2
            case .pressed: 3
            case .chain: 3
            case .led: 4
            }
        }
    }

    struct Item {
        let channel: Channel
        let color: UInt32
        let code: Int
    }

    // btn[x][y][priority]
    private var btn: [[[Item?]]]
    // cir[index][priority]
    private var cir: [[Item?]]
    private var btnIgnoreList: [Bool]
    private var cirIgnoreList: [Bool]

    private static let prioritySlotCount = 5

    init(x: Int, y: Int) {
        btn = Array(
            repeating: Array(
                repeating: Array(repeating: nil as Item?, count: Self.prioritySlotCount),
                count: y
            ),
            count: x
        )
        cir = Array(
            repeating: Array(repeating: nil as Item?, count: Self.prioritySlotCount),
            count: Self.circularButtonCount
        )
        btnIgnoreList = Array(repeating: false, count: Self.prioritySlotCount)
        cirIgnoreList = Array(repeating: false, count: Self.prioritySlotCount)
    }

    func get(x: Int, y: Int) -> Item? {
        if x != -1 {
            for i in 0..<Self.prioritySlotCount {
                if btnIgnoreList[i] { continue }
                if let item = btn[x][y][i] {
                    return item
                }
            }
        } else {
            for i in 0..<Self.prioritySlotCount {
                if cirIgnoreList[i] { continue }
                if let item = cir[y][i] {
                    return item
                }
            }
        }
        return nil
    }

    func add(x: Int, y: Int, channel: Channel, color: Int, code: Int) {
        let resolvedColor: UInt32
        if color == -1 {
            resolvedColor = LaunchpadColor.colorFromCode(code)
        } else {
            resolvedColor = UInt32(truncatingIfNeeded: color)
        }

        let item = Item(channel: channel, color: resolvedColor, code: code)
        if x != -1 {
            btn[x][y][channel.priority] = item
        } else {
            cir[y][channel.priority] = item
        }
    }

    func get(x: Int, y: Int, channel: Channel) -> Item? {
        if x != -1 {
            return btn[x][y][channel.priority]
        } else {
            return cir[y][channel.priority]
        }
    }

    func remove(x: Int, y: Int, channel: Channel) {
        if x != -1 {
            btn[x][y][channel.priority] = nil
        } else {
            cir[y][channel.priority] = nil
        }
    }

    func setBtnIgnore(channel: Channel, ignore: Bool) {
        btnIgnoreList[channel.priority] = ignore
    }

    func setCirIgnore(channel: Channel, ignore: Bool) {
        cirIgnoreList[channel.priority] = ignore
    }
}
