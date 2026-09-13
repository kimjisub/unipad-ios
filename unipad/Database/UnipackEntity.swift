import Foundation
import SwiftData

/// Stored on the user's device since the first release. Do not add, remove, rename, or retype a
/// property here on its own: that needs a new schema version and a migration stage, as described in
/// `UnipadSchema.swift`. Without them SwiftData either drops data in a migration it infers by itself
/// or cannot open the existing store, and then no bookmark or play count is loaded or kept.
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
