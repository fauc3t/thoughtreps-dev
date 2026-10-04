# Thought Reps

Local-first iPhone app: write a Markdown thought, and it resurfaces on the timeline after an interval (7 days by default). Spec and mockups are in `designs/` (don't edit); `landing/` is unrelated landing-page prototypes. Setup and commands are in README.md and DEVELOPMENT.md.

## Stack

Swift, SwiftUI, SwiftData, iOS 17+, Swift Testing. No third-party dependencies yet (Markdown renderer is a pending spike). Paid Apple Developer account.

## Workflow

- `project.yml` is the source of truth. `ThoughtReps.xcodeproj` is generated and gitignored: edit `project.yml`, run `xcodegen`, never hand-edit the project. Re-run after adding or removing files.
- Signing lives in `Config/Local.xcconfig` (gitignored, copy from the `.example`).
- Test: `xcodegen && xcodebuild test -scheme ThoughtReps -destination 'platform=iOS Simulator,name=<simulator>'`, with a name from `xcrun simctl list devices available`.

## Rules

- **Scheduling is pure.** All resurfacing logic lives in `ThoughtReps/Scheduler/` as pure functions that take `now` as a parameter; never call `Date.now` inside them. `ThoughtStore` methods also take `now` with no default; views pass `.now`. Cover changes with tests in `ThoughtRepsTests/`.
- **`ThoughtStore` owns all writes.** Views read via `@Query` but mutate (create, edit, schedule, tags, delete) only through the store.
- **Models stay CloudKit-compatible** so iCloud sync can be switched on later without a migration: every stored property has a default, relationships are optional with inverses declared on one side, no `@Attribute(.unique)` (e.g. tag uniqueness is enforced in `ThoughtStore`), and enums are stored as raw strings.

## Product decisions

- **Opening a thought requeues it (for now).** `ThoughtDetailView` calls `ThoughtStore.markViewed` on appear. The user is trying this UX before deciding whether to switch to an explicit Requeue button on the full-screen thought page, so don't change it without asking.
- **v1 blocks are blurred text only** (`BlockKind.blurred`).
- **No legacy data import.** Export/import is only for the app's own format.
