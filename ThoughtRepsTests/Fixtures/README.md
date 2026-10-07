# Fixtures

`default.store` is a SwiftData store written by the app's pre-launch V1 schema (Thought, Tag, Block,
ImageAsset, with image pixels stored in the database). It holds four thoughts (pinned with two
blurred markdown blocks, viewed twice with an inline image, archived with a two-image gallery, plain), three
tags and three images. The images are small, so SwiftData keeps them inside the file (larger ones go
to a `.default_SUPPORT/_EXTERNAL_DATA` folder beside the store). The WAL was checkpointed when it was
copied, so the single file is complete.

`PersistenceTests.openV1FixtureWithMigrationPlan` copies it to a temp directory and opens it with the
current code and migration plan.

The app has not launched, so V1 was still edited in place when images were added (the file was
regenerated from the new models; the earlier one, from before images, is gone). From launch on it
stands in for data already on users' devices: never regenerate or edit it. When the schema changes,
add a new fixture beside it rather than replacing this one.

## How it was made

`FixtureGenerator` (in `ThoughtRepsTests/`) builds it through `ThoughtStore`. It only runs when
`GENERATE_FIXTURE_TO` is set:

```
mkdir /tmp/fixture
TEST_RUNNER_GENERATE_FIXTURE_TO=/tmp/fixture xcodebuild test -scheme ThoughtReps \
  -destination 'platform=iOS Simulator,name=<simulator>' -only-testing:ThoughtRepsTests/FixtureGenerator
sqlite3 /tmp/fixture/default.store 'PRAGMA wal_checkpoint(TRUNCATE);'
cp /tmp/fixture/default.store ThoughtRepsTests/Fixtures/default.store
```

Make sure no `default.store-shm` or `-wal` ends up in this folder.
