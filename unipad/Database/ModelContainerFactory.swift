import Foundation
import SwiftData

/// What opening the SwiftData store produced for this launch.
struct ModelStoreOpenResult {
    let container: ModelContainer
    /// Why the on-disk store could not be opened. When set, `container` lives in memory: saved
    /// bookmarks and play counts are not visible and nothing changed now outlives the process.
    let persistentStoreError: (any Error)?

    var isTemporary: Bool { persistentStoreError != nil }
}

enum ModelContainerFactory {
    static var schema: Schema { Schema(versionedSchema: UnipadSchemaV1.self) }

    /// Opens the on-disk store (the default store when `storeURL` is nil) through `UnipadMigrationPlan`.
    ///
    /// If that fails it returns an in-memory container together with the error rather than throwing:
    /// a crash on every launch is worse, and the only way out of one (reinstalling) also deletes every
    /// UniPack in Documents. The store file is never deleted, moved, or rewritten here, so a later
    /// build that can open it still finds the user's data.
    static func make(storeURL: URL? = nil) -> ModelStoreOpenResult {
        do {
            return ModelStoreOpenResult(container: try openPersistent(storeURL: storeURL), persistentStoreError: nil)
        } catch {
            NSLog("Could not open the SwiftData store, running on an in-memory store: \(error)")
            do {
                return ModelStoreOpenResult(container: try openInMemory(), persistentStoreError: error)
            } catch {
                fatalError("Could not create in-memory ModelContainer: \(error)")
            }
        }
    }

    static func openPersistent(storeURL: URL? = nil) throws -> ModelContainer {
        let schema = schema
        let configuration: ModelConfiguration
        if let storeURL {
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }
        return try ModelContainer(
            for: schema,
            migrationPlan: UnipadMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func openInMemory() throws -> ModelContainer {
        let schema = schema
        return try ModelContainer(
            for: schema,
            migrationPlan: UnipadMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }
}
