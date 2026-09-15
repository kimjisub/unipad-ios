import CoreData
import Foundation
import SwiftData
import Testing
@testable import unipad

@MainActor
struct ModelContainerFactoryTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ModelContainerFactoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes one row the way every build before the versioned schema did: a plain `Schema` with no
    /// `VersionedSchema` and no migration plan. The container is released before returning, as it
    /// would be when that build quits and the updated one launches.
    private func writeWithUnversionedSchema(at storeURL: URL, _ entity: UnipackEntity) throws {
        let schema = Schema([UnipackEntity.self])
        let legacy = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: storeURL)])
        let context = ModelContext(legacy)
        context.insert(entity)
        try context.save()
    }

    private func versionHashes(at storeURL: URL) throws -> [String: Data] {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
        return try #require(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
    }

    /// Core Data's own test for "this store needs no migration to be opened with this model".
    /// `makeManagedObjectModel(for:)` only exists from iOS 26, so callers gate on it.
    @available(iOS 26.0, *)
    private func v1IsCompatible(withStoreAt storeURL: URL) throws -> Bool {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: Schema(versionedSchema: UnipadSchemaV1.self)))
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL)
        return model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
    }

    @Test func aStoreWrittenByTheUnversionedSchemaOpensUnderV1WithoutMigrating() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "default.store")
        let lastOpenedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let createdAt = Date(timeIntervalSince1970: 1_760_000_000)

        try writeWithUnversionedSchema(
            at: storeURL,
            UnipackEntity(id: "pack-a", bookmark: true, openCount: 42, lastOpenedAt: lastOpenedAt, createdAt: createdAt)
        )
        let hashesWrittenByTheShippedSchema = try versionHashes(at: storeURL)

        // Same version hashes as V1, so opening it is not a migration, inferred or otherwise.
        // Before iOS 26 this direct check is unavailable; the unchanged hashes at the end still cover it.
        if #available(iOS 26.0, *) {
            #expect(try v1IsCompatible(withStoreAt: storeURL))
        }

        do {
            let opened = ModelContainerFactory.make(storeURL: storeURL)
            #expect(opened.persistentStoreError == nil, "store did not open: \(String(describing: opened.persistentStoreError))")
            #expect(!opened.isTemporary)
            #expect(opened.container.configurations.allSatisfy { !$0.isStoredInMemoryOnly })

            let rows = try ModelContext(opened.container).fetch(FetchDescriptor<UnipackEntity>())
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.id == "pack-a")
            #expect(row.bookmark == true)
            #expect(row.openCount == 42)
            #expect(row.lastOpenedAt == lastOpenedAt)
            #expect(row.createdAt == createdAt)
        }

        #expect(try versionHashes(at: storeURL) == hashesWrittenByTheShippedSchema)
    }

    @Test func aStoreOpenedUnderV1KeepsWritesAcrossTheNextLaunch() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "default.store")

        try writeWithUnversionedSchema(at: storeURL, UnipackEntity(id: "pack-a", openCount: 1))

        do {
            let firstLaunch = ModelContainerFactory.make(storeURL: storeURL)
            #expect(!firstLaunch.isTemporary)
            let context = ModelContext(firstLaunch.container)
            let row = try #require(try context.fetch(FetchDescriptor<UnipackEntity>()).first)
            row.openCount += 1
            row.bookmark = true
            context.insert(UnipackEntity(id: "pack-b"))
            try context.save()
        }

        let secondLaunch = ModelContainerFactory.make(storeURL: storeURL)
        #expect(secondLaunch.persistentStoreError == nil, "store did not reopen: \(String(describing: secondLaunch.persistentStoreError))")
        let rows = try ModelContext(secondLaunch.container)
            .fetch(FetchDescriptor<UnipackEntity>(sortBy: [SortDescriptor(\.id)]))
        #expect(rows.map(\.id) == ["pack-a", "pack-b"])
        #expect(rows.first?.openCount == 2)
        #expect(rows.first?.bookmark == true)
    }

    @Test func anUnreadableStoreFallsBackToMemoryAndLeavesTheFileUntouched() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "default.store")
        let unreadable = Data(repeating: 0x42, count: 8192)
        try unreadable.write(to: storeURL)

        let opened = ModelContainerFactory.make(storeURL: storeURL)

        #expect(opened.isTemporary)
        #expect(opened.persistentStoreError != nil)
        #expect(opened.container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        #expect(try Data(contentsOf: storeURL) == unreadable)

        // The temporary store still works for this launch, so the app stays usable.
        let context = ModelContext(opened.container)
        context.insert(UnipackEntity(id: "pack-c"))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<UnipackEntity>()) == 1)
        #expect(try Data(contentsOf: storeURL) == unreadable)
    }

    /// The control for the compatibility check above. Reopening with rows intact is not enough on its
    /// own: SwiftData quietly applies any migration it can infer, so a store with an extra attribute
    /// also "opens" under V1 (and loses that column). The version-hash check is what tells them apart.
    @available(iOS 26.0, *)
    @Test func theCompatibilityCheckRejectsADifferentEntityShape() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "default.store")

        let changedSchema = Schema([ChangedShape.UnipackEntity.self])
        #expect(changedSchema.entities.map(\.name) == ["UnipackEntity"])
        do {
            let changed = try ModelContainer(for: changedSchema, configurations: [ModelConfiguration(schema: changedSchema, url: storeURL)])
            let context = ModelContext(changed)
            context.insert(ChangedShape.UnipackEntity(id: "pack-d", rating: 5))
            try context.save()
        }

        #expect(try v1IsCompatible(withStoreAt: storeURL) == false)
    }

    /// A store V1 cannot be migrated to, which is what an incompatible model change without a
    /// migration stage produces: the app falls back, and the data stays readable by the schema that wrote it.
    @Test func aStoreThatCannotBeMigratedFallsBackAndKeepsItsData() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "default.store")

        let retypedSchema = Schema([RetypedShape.UnipackEntity.self])
        do {
            let retyped = try ModelContainer(for: retypedSchema, configurations: [ModelConfiguration(schema: retypedSchema, url: storeURL)])
            let context = ModelContext(retyped)
            context.insert(RetypedShape.UnipackEntity(id: "pack-e", openCount: "7"))
            try context.save()
        }
        let hashesBefore = try versionHashes(at: storeURL)

        do {
            let opened = ModelContainerFactory.make(storeURL: storeURL)
            #expect(opened.isTemporary, "a store with a retyped attribute opened under V1")
            #expect(opened.persistentStoreError != nil)
            #expect(opened.container.configurations.allSatisfy { $0.isStoredInMemoryOnly })
        }

        #expect(try versionHashes(at: storeURL) == hashesBefore)
        let reopened = try ModelContainer(for: retypedSchema, configurations: [ModelConfiguration(schema: retypedSchema, url: storeURL)])
        let rows = try ModelContext(reopened).fetch(FetchDescriptor<RetypedShape.UnipackEntity>())
        #expect(rows.map(\.id) == ["pack-e"])
        #expect(rows.first?.openCount == "7")
    }

    @Test func theMigrationPlanEndsAtTheSchemaTheAppOpens() {
        #expect(UnipadMigrationPlan.schemas.last.map { ObjectIdentifier($0) } == ObjectIdentifier(UnipadSchemaV1.self))
        #expect(ModelContainerFactory.schema.version == UnipadMigrationPlan.schemas.last?.versionIdentifier)
        #expect(ModelContainerFactory.schema.entities.map(\.name) == ["UnipackEntity"])
        // A plain `Schema([...])`, which is what shipped, already carries version 1.0.0.
        #expect(Schema([UnipackEntity.self]).version == UnipadSchemaV1.versionIdentifier)
    }
}

/// `UnipackEntity` as it would look if someone added a property without adding a schema version.
private enum ChangedShape {
    @Model
    final class UnipackEntity {
        @Attribute(.unique)
        var id: String
        var bookmark: Bool
        var openCount: Int64
        var lastOpenedAt: Date?
        var createdAt: Date
        var rating: Int

        init(id: String, rating: Int) {
            self.id = id
            self.bookmark = false
            self.openCount = 0
            self.lastOpenedAt = nil
            self.createdAt = Date()
            self.rating = rating
        }
    }
}

/// `UnipackEntity` with `openCount` stored as text, a change SwiftData cannot infer a migration for.
private enum RetypedShape {
    @Model
    final class UnipackEntity {
        @Attribute(.unique)
        var id: String
        var bookmark: Bool
        var openCount: String
        var lastOpenedAt: Date?
        var createdAt: Date

        init(id: String, openCount: String) {
            self.id = id
            self.bookmark = false
            self.openCount = openCount
            self.lastOpenedAt = nil
            self.createdAt = Date()
        }
    }
}

private final class RecordingCrashlytics: CrashlyticsServiceProtocol, @unchecked Sendable {
    private(set) var messages: [String] = []
    private(set) var recorded: [any Error] = []

    func setCrashlyticsCollectionEnabled(_ enabled: Bool) {}

    func log(_ message: String) {
        messages.append(message)
    }

    func record(_ error: Error) {
        recorded.append(error)
    }
}

private struct StoreOpenFailure: Error {}

@MainActor
struct ModelStoreStatusTests {
    @Test func aStoreThatOpenedShowsNoNoticeAndReportsNothing() {
        let status = ModelStoreStatus(openError: nil)
        let crashlytics = RecordingCrashlytics()

        status.reportIfNeeded(to: crashlytics)

        #expect(!status.isTemporary)
        #expect(!status.showsNotice)
        #expect(crashlytics.recorded.isEmpty)
        #expect(crashlytics.messages.isEmpty)
    }

    @Test func aTemporaryStoreShowsTheNoticeUntilDismissed() {
        let status = ModelStoreStatus(openError: StoreOpenFailure())

        #expect(status.isTemporary)
        #expect(status.showsNotice)

        status.dismissNotice()

        #expect(!status.showsNotice)
        #expect(status.isTemporary)
    }

    @Test func aTemporaryStoreIsReportedAsANonFatalOnce() {
        let status = ModelStoreStatus(openError: StoreOpenFailure())
        let crashlytics = RecordingCrashlytics()

        status.reportIfNeeded(to: crashlytics)
        status.reportIfNeeded(to: crashlytics)

        #expect(crashlytics.recorded.count == 1)
        #expect(crashlytics.recorded.first is StoreOpenFailure)
        #expect(crashlytics.messages.count == 1)
    }
}
