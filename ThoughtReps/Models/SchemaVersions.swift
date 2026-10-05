import Foundation
import SwiftData

/// The on-disk schema as first shipped.
///
/// It references the live model classes, so it is not frozen: editing a live model changes
/// V1's hash and the shipped store no longer matches it. Before the first schema change,
/// snapshot V1 into nested copies of the current models, then add `SchemaV2` and a
/// migration stage. `PersistenceTests.openV1FixtureWithMigrationPlan` guards this.
enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [Thought.self, Tag.self, Block.self, ImageAsset.self]
    }
}

enum ThoughtRepsMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

extension ModelContainer {
    /// The app's container. With no `url` it uses SwiftData's default store (`default.store`
    /// in Application Support), the same file the unversioned container used.
    static func thoughtReps(url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let url {
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema)
        }
        return try ModelContainer(for: schema, migrationPlan: ThoughtRepsMigrationPlan.self, configurations: configuration)
    }
}
