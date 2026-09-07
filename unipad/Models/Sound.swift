import Foundation

struct Sound {
    static let noWormhole = -1
    // Packs are parsed on the main thread and inside the importer/downloader actors at the same
    // time; an unsynchronized counter could hand two sounds the same id (the SoundEngine buffer key).
    private static let idLock = NSLock()
    nonisolated(unsafe) private static var nextId = 0

    private static func allocateId() -> Int {
        idLock.lock()
        defer { idLock.unlock() }
        let id = nextId
        nextId += 1
        return id
    }

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
        self.id = Sound.allocateId()
    }
}
