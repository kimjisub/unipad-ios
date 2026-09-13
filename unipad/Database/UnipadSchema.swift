import Foundation
import SwiftData

/// The schema every build before this one shipped unversioned, as `Schema([UnipackEntity.self])`
/// (which also carries version 1.0.0). Same entity and attributes, so a store those builds wrote has
/// V1's version hashes and opens with no migration at all; `ModelContainerFactoryTests` checks this
/// against a store written the old way.
///
/// Changing `UnipackEntity` means adding a version, not editing this one:
/// 1. copy the current `UnipackEntity` into an `extension UnipadSchemaV1` so V1 keeps describing the
///    store that is on people's devices,
/// 2. add `UnipadSchemaV2` whose `models` is the changed class,
/// 3. append V2 to `UnipadMigrationPlan.schemas` and a `MigrationStage` from V1 to V2 to `stages`,
/// 4. point `ModelContainerFactory.schema` at V2.
/// Nothing stops a build that skips this. SwiftData applies whatever migration it can infer on its own,
/// which silently drops the values of a property the new model no longer has, and a change it cannot
/// infer (a retyped property, for one) leaves the store unopenable, so the app runs on a temporary store.
nonisolated enum UnipadSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [UnipackEntity.self]
    }
}

nonisolated enum UnipadMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [UnipadSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
