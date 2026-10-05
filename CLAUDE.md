# Thought Reps

Local-first iPhone app: write a Markdown thought, and it resurfaces on the timeline after an interval (7 days by default). Spec and mockups are in `designs/` (don't edit); `landing/` is unrelated landing-page prototypes. Setup and commands are in README.md and DEVELOPMENT.md.

## Stack

Swift, SwiftUI, SwiftData, iOS 18+, Swift Testing. No third-party dependencies yet (Markdown renderer is a pending spike). Paid Apple Developer account.

## Workflow

- `project.yml` is the source of truth. `ThoughtReps.xcodeproj` is generated and gitignored: edit `project.yml`, run `xcodegen`, never hand-edit the project. Re-run after adding or removing files.
- Signing lives in `Config/Local.xcconfig` (gitignored, copy from the `.example`).
- Test: `xcodegen && xcodebuild test -scheme ThoughtReps -destination 'platform=iOS Simulator,name=<simulator>'`, with a name from `xcrun simctl list devices available`.

## Rules

- **Scheduling is pure.** All resurfacing logic lives in `ThoughtReps/Scheduler/` as pure functions that take `now` as a parameter; never call `Date.now` inside them. `ThoughtStore` methods also take `now` with no default; views pass `.now`. Cover changes with tests in `ThoughtRepsTests/`.
- **`ThoughtStore` owns all writes.** Views read via `@Query` but mutate (create, edit, schedule, tags, delete) only through the store.
- **Models stay CloudKit-compatible** so iCloud sync can be switched on later without a migration: every stored property has a default, relationships are optional with inverses declared on one side, no `@Attribute(.unique)` (e.g. tag uniqueness is enforced in `ThoughtStore`), and enums are stored as raw strings.
- **Schema changes need a migration.** The app container is built from `SchemaV1` + `ThoughtRepsMigrationPlan` (`Models/SchemaVersions.swift`). `SchemaV1` points at the live model classes, so before ANY model change, snapshot V1 into nested copies, then add `SchemaV2` and a migration stage. Never regenerate or edit `ThoughtRepsTests/Fixtures/default.store` (a pre-versioning install; see the README beside it); add a new fixture for new versions. `PersistenceTests.openV1FixtureWithMigrationPlan` guards this.
- **Saves can fail and must not be swallowed.** `ThoughtStore.persist()` logs, rolls back, and reports to `SaveErrorCenter` (shown as an alert). Store writers return `Bool` (`@discardableResult`); a failed create returns a detached thought (`modelContext == nil`). The editor closes only on success so drafts survive. Rolling back certain write shapes crashes SwiftData, so new writes on a stored thought must follow the rules in the `persist()` note (`update` saves in steps and may be partly saved on failure; `delete` removes children explicitly).
- **Keep the integrity checker and randomized tests current.** `IntegrityChecker` (`Stores/`) is a pure, read-only invariant check that runs at launch in DEBUG and only logs. When adding or changing a model field, store write, or invariant, extend it and the seeded random-operation tests (with injected save failures) so every operation keeps the store violation-free.
- **If the store can't open, show the error screen** ("Couldn't open your thoughts"); never fall back to creating an empty store.

## Product decisions

- **Opening a thought requeues it (for now).** `ThoughtDetailView` calls `ThoughtStore.markViewed` on appear. The user is trying this UX before deciding whether to switch to an explicit Requeue button on the full-screen thought page, so don't change it without asking.
- **v1 blocks are blurred text only** (`BlockKind.blurred`).
- **No legacy data import.** Export/import is only for the app's own format.
