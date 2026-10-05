# Fixtures

`default.store` is a SwiftData store written by the app's schema as first shipped (V1: Thought,
Tag, Block, ImageAsset), created with a plain `ModelContainer(for:configurations:)` and no
`VersionedSchema`, the way existing installs were. It holds four thoughts (pinned with two blocks,
viewed twice, archived, plain) and three tags. The WAL was empty (checkpointed) when it was copied,
so the single file is complete.

`PersistenceTests.openV1FixtureWithMigrationPlan` copies it to a temp directory and opens it with the
current code and migration plan.

Never regenerate or edit it: it stands in for data already on users' devices. When the schema
changes, add a new fixture beside it rather than replacing this one.
