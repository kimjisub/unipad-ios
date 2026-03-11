import Foundation
import SwiftData

@Model
final class UnipackEntity {
    @Attribute(.unique)
    var id: String
    var bookmark: Bool
    var openCount: Int64
    var lastOpenedAt: Date?
    var createdAt: Date

    init(id: String, bookmark: Bool = false, openCount: Int64 = 0, lastOpenedAt: Date? = nil, createdAt: Date = Date()) {
        self.id = id
        self.bookmark = bookmark
        self.openCount = openCount
        self.lastOpenedAt = lastOpenedAt
        self.createdAt = createdAt
    }

    static func create(id: String) -> UnipackEntity {
        UnipackEntity(id: id)
    }
}
