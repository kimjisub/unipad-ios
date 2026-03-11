import Foundation

struct Sound {
    static let noWormhole = -1
    private static var nextId = 0

    let file: URL
    let loop: Int
    let wormhole: Int
    var num: Int
    let id: Int

    init(file: URL, loop: Int, wormhole: Int = noWormhole, num: Int = 0) {
        self.file = file
        self.loop = loop
        self.wormhole = wormhole
        self.num = num
        self.id = Sound.nextId
        Sound.nextId += 1
    }
}
