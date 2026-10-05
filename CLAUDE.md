# Thought Reps

Local-first iPhone app: write a Markdown thought, and it resurfaces on the timeline after an interval (7 days by default). Spec and mockups are in `designs/` (don't edit); `landing/` is unrelated landing-page prototypes. Setup and commands are in README.md and DEVELOPMENT.md.

## Stack

Swift, SwiftUI, SwiftData, iOS 18+, Swift Testing. One third-party dependency: MarkdownUI (pinned exact; chosen over Textual as the stable option, though it's in maintenance mode). Add packages via `project.yml` `packages:`; the SwiftPM lockfile `ThoughtReps.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` is tracked, so commit it when versions change. Paid Apple Developer account.

## Workflow

- `project.yml` is the source of truth. `ThoughtReps.xcodeproj` is generated and gitignored: edit `project.yml`, run `xcodegen`, never hand-edit the project. Re-run after adding or removing files.
- Signing lives in `Config/Local.xcconfig` (gitignored, copy from the `.example`).
- Test: `xcodegen && xcodebuild test -scheme ThoughtReps -destination 'platform=iOS Simulator,name=<simulator>'`, with a name from `xcrun simctl list devices available`.

## Rules

- **Scheduling is pure.** All resurfacing logic lives in `ThoughtReps/Scheduler/` as pure functions that take `now` as a parameter; never call `Date.now` inside them. `ThoughtStore` methods also take `now` with no default; views pass `.now`. Cover changes with tests in `ThoughtRepsTests/`.
- **Reminders: plan purely, schedule in one place.** What to notify and when is `ReminderPlanner` (pure, in `Scheduler/`). Only `NotificationScheduler.reschedule` touches `UNUserNotificationCenter`; it is serialized and removes stale reminders before adding the planned ones, so no more than 7 are ever pending. Local notifications only (no push), no app icon badge, and pinned thoughts never count.
- **Tag links go through `TagLinker`.** It rewrites `#tag` to a `thoughtreps-tag:` link before MarkdownUI renders, using `TagParser`'s rules; don't parse tags separately in the renderer.
- **`ThoughtStore` owns all writes.** Views read via `@Query` but mutate (create, edit, schedule, tags, delete) only through the store.
- **Models stay CloudKit-compatible** so iCloud sync can be switched on later without a migration: every stored property has a default, relationships are optional with inverses declared on one side, no `@Attribute(.unique)` (e.g. tag uniqueness is enforced in `ThoughtStore`), and enums are stored as raw strings.
- **Schema changes need a migration.** The app container is built from `SchemaV1` + `ThoughtRepsMigrationPlan` (`Models/SchemaVersions.swift`). `SchemaV1` points at the live model classes, so before ANY model change, snapshot V1 into nested copies, then add `SchemaV2` and a migration stage. Never regenerate or edit `ThoughtRepsTests/Fixtures/default.store` (a pre-versioning install; see the README beside it); add a new fixture for new versions. `PersistenceTests.openV1FixtureWithMigrationPlan` guards this.
- **Saves can fail and must not be swallowed.** `ThoughtStore.persist()` logs, rolls back, and reports to `SaveErrorCenter` (shown as an alert). Store writers return `Bool` (`@discardableResult`); a failed create returns a detached thought (`modelContext == nil`). The editor closes only on success so drafts survive. Rolling back certain write shapes crashes SwiftData, so new writes on a stored thought must follow the rules in the `persist()` note (`update` saves in steps and may be partly saved on failure; `delete` removes children explicitly).
- **Keep the integrity checker and randomized tests current.** `IntegrityChecker` (`Stores/`) is a pure, read-only invariant check that runs at launch in DEBUG and only logs. When adding or changing a model field, store write, or invariant, extend it and the seeded random-operation tests (with injected save failures) so every operation keeps the store violation-free.
- **The share extension never touches SwiftData.** `ThoughtRepsShare` only writes `InboxItem` files into the App Group inbox via `Shared/`; the app imports them through `InboxImporter` -> `ThoughtStore.create`. The store stays in the app container: moving it to the App Group would need a migration plan, so don't do it casually. Keep the extension free of MarkdownUI and SwiftData (extension memory limit).
- **Generated plists and entitlements come from `project.yml`** (`info:`/`entitlements:`, gitignored output); never hand-edit them.
- **If the store can't open, show the error screen** ("Couldn't open your thoughts"); never fall back to creating an empty store.

## Product decisions

- **Opening a thought requeues it (until Study mode ships).** `ThoughtDetailView` calls `ThoughtStore.markViewed` on appear. Study mode (v1 release, see the spec) replaces this for thoughts opened from the due list with **Again** / **Got it**; thoughts opened elsewhere (pinned, tag "All", search) keep the plain view. Don't change the current behavior outside that work without asking.
- **v1 blocks are blurred text only** (`BlockKind.blurred`).
- **No legacy data import for now.** Export/import is only for the app's own format. Importing the original Thought Reps data is still an open question in the spec; don't build it until that's answered.
