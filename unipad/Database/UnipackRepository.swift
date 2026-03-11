import Foundation
import SwiftData

final class UnipackRepository: Sendable {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    @MainActor
    func find(id: String) throws -> UnipackEntity? {
        let context = modelContainer.mainContext
        let predicate = #Predicate<UnipackEntity> { $0.id == id }
        let descriptor = FetchDescriptor(predicate: predicate)
        return try context.fetch(descriptor).first
    }

    @MainActor
    func getOrCreate(id: String) throws -> UnipackEntity {
        if let existing = try find(id: id) {
            return existing
        }
        let entity = UnipackEntity.create(id: id)
        modelContainer.mainContext.insert(entity)
        try modelContainer.mainContext.save()
        return entity
    }

    @MainActor
    func toggleBookmark(id: String) throws {
        guard let entity = try find(id: id) else { return }
        entity.bookmark.toggle()
        try modelContainer.mainContext.save()
    }

    @MainActor
    func totalOpenCount() throws -> Int64 {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<UnipackEntity>()
        let all = try context.fetch(descriptor)
        return all.reduce(0) { $0 + $1.openCount }
    }

    @MainActor
    func openCount(id: String) throws -> Int64 {
        try find(id: id)?.openCount ?? 0
    }

    @MainActor
    func lastOpenedAt(id: String) throws -> Date? {
        try find(id: id)?.lastOpenedAt
    }

    @MainActor
    func recordOpen(id: String) throws {
        guard let entity = try find(id: id) else { return }
        entity.openCount += 1
        entity.lastOpenedAt = Date()
        try modelContainer.mainContext.save()
    }
}
