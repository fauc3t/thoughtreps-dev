# Thought Reps for iPhone — Design Spec

Oct 4, 2026 · @Nick

## Overview & goals

Thought Reps is a native iPhone app for capturing thoughts and having them come back on a schedule, so ideas get revisited instead of forgotten. Everything lives on the device; no account or server is required.

Goals for v1:

- Capture a thought in under 5 seconds from launch, written in Markdown with images.
- Resurface each thought on a timeline after its interval (default 7 days); viewing it re-queues it.
- Pin thoughts to keep them always visible; archive thoughts to retire them.
- Organize with inline `#hashtags`, with a timeline per tag.
- Attach extra blocks to a thought: Markdown text (optionally blurred until tapped) and image galleries.

Non-goals for v1: multi-user sharing, a web or Android client, a backend, and AI features. iCloud sync is designed for but ships in a later milestone.

## Core concepts & resurfacing rules

A thought is either waiting, due, pinned or archived, and only two things move it: time passing and the user acting on it.

&#91;embedded content: thought lifecycle · 5 states\]

Time moves a thought from waiting to due; a view or snooze sends it back, and archive takes it out of the loop until restored.

- **Waiting.** A new thought gets `nextDueAt = createdAt + interval`. It does not appear on the main timeline until then.
- **Due.** Once `nextDueAt <= now`, it shows on the timeline, oldest due first.
- **Viewed.** Opening a due thought marks it viewed: `lastViewedAt = now`, `viewCount += 1`, `nextDueAt = now + interval`. It leaves the due list when you return to the timeline, not while you are reading it.
- **Pinned.** Pinned thoughts sit in a section above the due list at all times. Viewing still updates `lastViewedAt` but never hides them.
- **Archived.** Archived thoughts never resurface. They live in the Archive screen and can be restored, which sets `nextDueAt = now`.
- **Snooze.** A swipe action pushes `nextDueAt` forward (1 day, 1 week, custom) without counting as a view.

**Study mode (v1 release).** When a due thought opens, the footer offers **Again** and **Got it** instead of counting the open as a view.

- Again: brings it back tomorrow and resets a growing interval.
- Got it: re-queues it on its interval; in growing mode, doubles the interval (capped at 365 days).
- Blurred text blocks act as the answer to recall before revealing.
- Thoughts opened outside the due list (pinned, tag "All", search) still record a plain view.

Intervals:

- Global default: 7 days, editable in Settings.
- Per-thought override: any thought can carry its own interval (for example 1 day for something being memorized).
- Growing intervals (v1 release, with Study mode): each **Got it** doubles the interval, capped at 365 days, and **Again** resets it. Stored as an `intervalMode` so it can be added without a migration.

Tags:

- Any `#word` in the body is a tag; tags are re-parsed on every save.
- A tag timeline applies the same due rules filtered to that tag, and also offers an "All" view that ignores due dates.
- Tags are case-insensitive and stored lowercase; the first spelling used is kept for display.

The main timeline query:

```
filter: !isArchived && (isPinned || nextDueAt <= now)
sort:   isPinned desc, nextDueAt asc
```

## Data model

Four SwiftData models cover v1. Every field has a default and every relationship is optional, which keeps the store compatible with CloudKit sync later.

**Thought**

| Field | Type | Notes |
| --- | --- | --- |
| id | UUID | Stable ID, used for image folders and export |
| body | String | Markdown source |
| createdAt | Date |  |
| updatedAt | Date | Set on every save |
| nextDueAt | Date | Drives the timeline |
| lastViewedAt | Date? |  |
| viewCount | Int | Default 0 |
| intervalDays | Int? | Nil = use global default |
| intervalMode | String | `fixed` now; `growing` later |
| isPinned | Bool |  |
| isArchived | Bool |  |
| archivedAt | Date? |  |
| tags | \[Tag\]? | Many-to-many, rebuilt from body on save |
| blocks | \[Block\]? | Cascade delete |
| images | \[ImageAsset\]? | Cascade delete |

**Tag**

| Field | Type | Notes |
| --- | --- | --- |
| name | String | Lowercased key, unique |
| displayName | String | First spelling used |
| colorHex | String? | Optional user color |
| thoughts | \[Thought\]? | Inverse of Thought.tags |

**Block** (extra content attached to a thought)

| Field | Type | Notes |
| --- | --- | --- |
| id | UUID |  |
| kind | String | `markdown` or `gallery` in v1; `quote`, `link`, `checklist` later. Old `blurred` records load as blurred `markdown` |
| content | String | Markdown for `markdown` blocks; unused for `gallery` |
| title | String? | Optional label, e.g. "Answer" (a gallery's title) |
| isBlurred | Bool | `markdown` only: hidden until tapped |
| order | Int | Position under the thought |
| thought | Thought? | Inverse |

**ImageAsset**

| Field | Type | Notes |
| --- | --- | --- |
| id | UUID |  |
| data, thumbnail | Data | `.externalStorage` (superseded the on-disk `filename`) |
| width, height | Int | For layout before load |
| thought | Thought? | Inverse |

Image bytes are stored in SwiftData as `.externalStorage` (see "As built"), not as files we manage, and referenced from Markdown as `![](img:<id>)`. Settings (default interval, notification time) live in `UserDefaults`.

## Screens & flows

The app has three tabs (Timeline, Tags, Archive) plus a capture button that is reachable from all of them. Settings opens from the Timeline toolbar.

| Screen | What it shows | Key actions |
| --- | --- | --- |
| Timeline | Pinned section, then due thoughts as cards: first lines rendered, tag chips, "due 3d ago" | Tap to open; swipe right to pin, left to archive or snooze; pull to refresh |
| Thought view | Full rendered Markdown, images, attached blocks, tags, "next up in 7 days" footer | Edit, pin, archive, change interval, share; opening it counts as a view |
| Editor | Markdown text field with a formatting bar, image picker, block list below | Bold, italic, heading, list, code, `#` tag autocomplete, add image, add block, save |
| Tags | All tags with counts of due and total thoughts | Tap for a tag timeline; long-press to rename, recolor or merge |
| Tag timeline | Same cards as Timeline, filtered by tag; toggle between Due and All | Same as Timeline |
| Archive | Archived thoughts, newest first, searchable | Restore, delete |
| Search | Full-text over body and blocks, from the Timeline toolbar | Open result |
| Settings | Default interval, daily reminder time, export and import, Send feedback (request a feature / report a problem) | Change values, export JSON + images |

Capture flow:

1. Tap the floating **+** button on any tab.
2. The editor opens with the keyboard up and the current tag pre-filled when you are in a tag timeline.
3. Type, optionally add images, more text blocks or a gallery.
4. Save. The thought is waiting and first comes due after its interval.

Review flow:

1. Open the app; due thoughts are on the Timeline.
2. Tap a card to read it. The view is recorded.
3. Go back; the card is gone until its next due date, unless pinned.
4. Or swipe to archive, pin or snooze without opening.

Empty states matter here: an empty Timeline says what is coming next ("3 thoughts come back tomorrow") rather than looking broken.

## Content: Markdown, images & blocks

Thought bodies are GitHub-flavored Markdown rendered with a third-party SwiftUI library, because Apple's built-in Markdown support only covers inline styles. The body is the thought's main text, always first; blocks are separate records rendered under it.

**Markdown rendering**

- Supported: headings, bold and italic, strikethrough, lists, task lists, quotes, inline and fenced code, links, tables, images.
- Library: [MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) is stable but now in maintenance mode; its author's newer library, [Textual](https://github.com/gonzalezreal/textual), is where new development happens. Milestone 1 includes a one-day spike to pick between them.
- Rendering sits behind a `ThoughtRenderer` view so the library can be swapped without touching screens.
- `#tags` are styled as tappable chips in rendered text and open that tag's timeline.

**Images**

- Added from the photo picker, camera or paste.
- Downscaled to a 2048 px longest edge, saved as HEIC, and referenced as `![](img:<id>)`.
- A custom image provider resolves `img:` URLs to local files. Deleting a thought deletes its image folder.

**Blocks**

| Kind | Behavior | Version |
| --- | --- | --- |
| Text | Markdown with an optional label, the same formatting bar, `#tags` and inline images as the body. A "Blur until tapped" toggle shows it under a heavy blur; tap to reveal, tap again to hide. Reveal state resets each time the thought opens. | v1 |
| Image gallery | A titled, horizontally scrolling row of images | v1 |
| Quote / source | A citation with author and link | Later |
| Checklist | Tickable items whose state persists | Later |
| Link preview | URL with a fetched title and image | Later |

The main text can't be removed or blurred. Title, timeline preview and pinning come from it. Tags from every text block file the thought, and search covers every text block, blurred too. Blocks are added from the editor's **Add block** menu (Text, Image gallery), reordered by drag, and each block kind is one SwiftUI view plus one case in a `BlockKind` enum, so new kinds stay small.

## Architecture & repo structure

The app is SwiftUI + SwiftData with no server, split so that the resurfacing rules are plain Swift that can be unit-tested without a UI.

**Stack**

- Swift 6, SwiftUI, SwiftData; minimum iOS 17 (first release with SwiftData).
- Swift Package Manager for the one dependency (Markdown renderer).
- Swift Testing for unit tests; XCUITest for one capture-and-review smoke test.
- Git repo on GitHub; Xcode signs with your Apple ID (free provisioning to start).

**Layers**

- **Views**: screens and reusable cards, no business logic.
- **Scheduler**: pure functions — `isDue`, `markViewed`, `snooze`, `nextDue(interval:mode:)` — taking a `now` parameter so tests control time.
- **Stores**: thin wrappers over `ModelContext` for queries (due list, by tag, search) and saves that run tag parsing.
- **Services**: `TagParser`, `ImageProcessor`, `NotificationScheduler`, `Exporter`.

**Repo layout**

```
ThoughtReps/
├── ThoughtReps.xcodeproj
├── ThoughtReps/
│   ├── App/            ThoughtRepsApp.swift, RootTabView.swift
│   ├── Models/         Thought, Tag, Block, ImageAsset
│   ├── Scheduler/      Scheduler.swift, IntervalMode.swift
│   ├── Stores/         ThoughtStore.swift, TagStore.swift
│   ├── Services/       TagParser, ImageProcessor, NotificationScheduler, Exporter
│   ├── Features/
│   │   ├── Timeline/   TimelineView, ThoughtCard
│   │   ├── Thought/    ThoughtDetailView, ThoughtRenderer
│   │   ├── Editor/     EditorView, FormatBar, BlockEditor
│   │   ├── Blocks/     BlockKind, BlockView
│   │   ├── Tags/       TagListView, TagTimelineView
│   │   ├── Archive/    ArchiveView
│   │   └── Settings/   SettingsView
│   └── Resources/      Assets.xcassets, sample data
├── ThoughtRepsTests/   SchedulerTests, TagParserTests, ExporterTests
├── ThoughtRepsUITests/ CaptureAndReviewTests
├── README.md
└── .gitignore          Xcode + macOS template
```

A `#if DEBUG` sample-data loader seeds about 20 thoughts with mixed due dates so every screen can be checked on first run.

## Notifications, backup & sync

All three are local-first: notifications are scheduled on-device, backup is a file you own, and sync is our own server (see the Sync Spec), not iCloud.

**Notifications (v1)**

- Superseded by "As built: Reminders": up to 7 daily reminders at a user-set time (default 8:00 AM), "4 thoughts are back today.", plus follow-ups at +14, +30 and +90 days, then silence.
- Rescheduled whenever the app goes to the background, using the count of thoughts due by each time.
- No reminder when nothing is due. Off until the user grants permission from Settings.

**Export and import (v1)**

- Export writes a `.thoughtreps` file (a zip, UTType `com.thoughtreps.export`) with `manifest.json`, `tags.jsonl`, `thoughts.jsonl`, `images/<uuid>` and `files/<uuid>` (exact layout: "As built: Backup file layout"), shared via the system share sheet to Files, AirDrop or iCloud Drive.
- Import reads the same format (also via Open in Thought Reps from Files or AirDrop) and merges by `id`, group by group (content, schedule, state, each by its own clock; "As built").
- Optional Markdown export: one `.md` file per thought with front matter (tags, dates, pinned) for use in other apps.

**One-time export link (fast follow)**

An optional way to get an export onto any device, such as a computer with no AirDrop or iCloud Drive. Together with feedback (below), it is the app's only server piece, and it only ever holds an encrypted file for a short time.

- **Share export as link** next to Export uploads the same `.thoughtreps` file (your whole log) to S3 and shows a link to copy or send, in the form `https://transfer.thoughtreps.com/x/<id>#<key>`. The S3 key is `exports/<random id>`.
- The zip is encrypted on the device before upload. The key is only in the link's `#` fragment, which browsers never send to the server, so the server and S3 only ever see ciphertext. Opening the link loads a small page that downloads the file, decrypts it in the browser and saves `ThoughtReps-export-<date>.thoughtreps` (only the browser's download name). The page title is "Your Thought Reps export".
- **One use:** the first download deletes the object. A small API (Lambda) issues a short-lived presigned URL once, marks the link used and deletes the object, so a second visit gets "This link has already been used." The claim happens on a **Download** tap, not on page load, so link previews can't use the link up.
- **Expires after 24 hours** if nobody uses it. A scheduled cleanup deletes anything older than 24h, with an S3 lifecycle rule as a backstop, because lifecycle rules alone run once a day and can leave a file for up to about 48h.
- No account and no sign-in. Uploads are capped at 100 MB and rate-limited per device. The app shows the expiry time, and the link can be revoked from the app before it's used.
- **One open link per device.** The server keys links by the install's App Attest key (so requests can't be faked from a script). Making a new link deletes the previous one if it's still unused, and Settings shows the open link with its expiry. Reinstalling the app gets a new key, which is acceptable because the 24h expiry still applies.

**iCloud sync (later)**

- SwiftData's CloudKit integration, enabled by adding the iCloud capability and a container.
- Requires the paid Apple Developer Program; the free Apple ID can't use CloudKit.
- The model rules above (defaults on every field, optional relationships, no unique constraints enforced by the database) are what make this a switch rather than a rewrite. Tag uniqueness is enforced in `TagStore` instead.

## Feedback & support

A **Send Feedback** section in Settings, sent through the app's own API (no Mail app needed) and no analytics SDK:

- Two options: **Request a Feature** and **Report a Problem**. Each opens an in-app form: the message (up to 5,000 characters) and a required email so we can reply. The email is remembered for next time.
- App version, iOS version and device model are shown on the form and sent with the message. Thought content is never attached.
- The request is signed with the install's App Attest key (same as the export link), and the server allows 3 messages per device per day; a send that fails doesn't count.
- The server emails it to hello@thoughtreps.com with the user's address as Reply-To.
- After the user opens 10 due thoughts (not pinned or archived), ask once for an App Store rating with Apple's built-in review prompt.
- Later, if volume grows, route the address into a helpdesk or a public feature-request board; no app change needed.

## Milestones & open questions

The build runs in four stages.

1. **Skeleton — done.** Repo, models, Scheduler with tests, timeline, thought view with view-to-requeue, pin, archive, snooze, editor with text and gallery blocks, tags and tag timelines, archive, settings, sample data.
2. **v1 release — must ship.**
    - Backup and export/import (zip of JSON + images; Markdown export).
    - Daily reminder notification.
    - Search across bodies and blocks.
    - Markdown renderer (MarkdownUI vs Textual spike) and images.
    - Study mode: Again / Got it, growing intervals, blurred text blocks as answers.
    - Send feedback / request a feature.
    - App Store prep: paid Apple Developer Program ($99/yr), app icon, privacy label, screenshots, TestFlight beta.
3. **Fast follow — driven by user requests.** Quick capture from anywhere: share extension, Lock Screen and Control Center button, Shortcuts/Siri "Add thought", home-screen widget. One-time export link (encrypted, single download, expires after 24h).
4. **Later.** iCloud sync, more block types, Face ID lock, themes and app icons.

Open questions:

- [ ] Do you have the original Thought Reps code or data to import? If so, which format?
- [x] Pricing: a paid download at $6.99, bought once. No subscription or in-app purchase in 1.0. Post-launch features are free updates for buyers.
- [x] Support email address for feedback: hello@thoughtreps.com.
- [ ] Privacy label and policy for feedback: Contact Info (email) and User Content, used for app support.
- [ ] One-time export link: how the privacy label and policy describe the temporary upload.
- [ ] Should viewing re-queue immediately on open, or only after a short dwell (e.g. 3 seconds) to avoid accidental views?
- [ ] Any block types from the original app beyond text and gallery that v1 should include?

## As built: app rules

What the shipped code does, kept here so CLAUDE.md can stay short. Where this contradicts an earlier section, this wins.

**Scale.** Counts and existence checks are `fetchCount`/`fetchLimit` queries with a `#Predicate`, never `@Query` arrays or relationships filtered in memory (SwiftData can't count through `tags?.isEmpty`; see `ThoughtCounts.untagged`). Predicates live in reusable builders, tested against an in-memory container: `ThoughtCounts`, the Timeline's `timeline`/`upcoming`/`nextUp` in `Stores/TimelineQueries.swift`, `ReminderPlanner.countedPredicate`, `ThoughtCounts.activeWithoutCopies`, the paged `conflictCopies(limit:in:)`, and the link builders `ThoughtCounts.targets(of:in:)` (one batched fetch per displayed thought) and `ThoughtCounts.linkedFrom(_:in:)` (capped at 50 + `fetchCount`, archived owners excluded). Load `Thought` objects only to display them, use `propertiesToFetch` when a few fields are enough, no query per thought (a query per tag is fine). Known exceptions: the Timeline's "show all" mode and the Archive list, and the DEBUG-only `IntegrityChecker`.

**Change clocks.** Writers stamp through the store's skew-safe `stamp` (`max(now, highestSeen + 1 ms)` when sync is on). Content (body, blocks, images, tags) is `updatedAt`; schedule (`nextDueAt`, interval, mode, `learnIntervalDays`) is `scheduleChangedAt`; pin/archive and `conflictOfID` (a plain id like `linkedThoughtID`, never the thought's own; import and sync conflict copies set it) are `stateChangedAt`. `markViewed` bumps the schedule clock only when it actually moves `nextDueAt`. `viewCount`/`lastViewedAt` have no clock (import takes the max). `Tag.updatedAt` is set only by an explicit color choice, so implicit tags stay `.distantPast`. `ThoughtStore.delete` writes a `Tombstone` in the same save (`SyncReconciler` queues unsynced ones; `deleteAll` clears them, and they aren't exported).

**Save failures.** `ThoughtStore.persist()` logs, rolls back, and reports to `SaveErrorCenter` (shown as an alert). Store writers return `Bool` (`@discardableResult`); a failed create returns a detached thought (`modelContext == nil`). The editor closes only on success so drafts survive. Rolling back certain write shapes crashes SwiftData, so new writes on a stored thought follow the rules in the `persist()` note (`update` saves in steps and may be partly saved on failure; `delete` removes children explicitly). New inline images are saved in their own step before the body edit, and inline images whose `![](img:<uuid>)` token left the body are deleted explicitly. `PendingImageSaves` marks a thought across that step; if the edit and the take-back both fail (or the app dies), the mark stays and `cleanUpPendingImageSaves()` (run at launch from `RootTabView`, and by `update` first) deletes the thought's tokenless inline images. `IntegrityChecker` covers images: data and thumbnails present, every inline image has a token and every token resolves, gallery images match their block's thought with contiguous order, images sit only in galleries or inline, no duplicate ids.

**Reminders.** `ReminderPlanner` (pure) plans; only `NotificationScheduler.reschedule` touches `UNUserNotificationCenter`, serialized, removing stale reminders before adding planned ones: at most 10 pending (7 daily plus follow-ups at +14, +30 and +90 days, then silence). Counts come from `fetchCount` with `countedPredicate`, never by loading thoughts; `plan` takes the count as a closure.

**Search index.** SQLite FTS5 in `Search/`, next to the store and excluded from backup. `SearchReconciler` repairs drift at launch (off the main thread, via an `updatedAt` + archive-flag fingerprint) and rebuilds a missing or damaged file. `SearchModel` takes an optional `isIncluded` filter (the link picker's exclusions) and keeps paging until a page's worth is visible. Index errors are logged, never shown. Known gaps: after a mid-session index failure search is incomplete until next launch, and a write that leaves `updatedAt` unchanged can leave stale text until the next edit.

**Layout.** Regular width is the three-column `SplitRootView`, compact is the iPhone tab view. `ThoughtSelection` (environment object) exists only in the split layout; list rows are `ThoughtLink` (a selection button there, a `NavigationLink` otherwise), and anything that leaves a thought (snooze, archive, delete) goes through `leave()`. The editor's keyboard format bar follows its text view's size class, not the device idiom or the keyboard window's traits. Never auto-select a thought: opening one is a view and requeues it. The one exception is a fold or unfold, which carries the selected tab's already-open thought and pushed screens across (`LayoutCarry`, `RootTabView.carryAcrossLayouts`) with a `ViewHandoff` that counts every carried thought entry (selection and linked-thought pushes, which stay pushes on the detail column's `ThoughtSelection.detailPath`, without changing the selection; `clear(ifSelected:)` truncates it), so no remounted detail, covered ones popped to later included, records a second view; it doesn't expire and is cleared by the next `select`/`clear` or carry. Editor sheets are presented from the root, so they survive a window resize.

**One scene.** Multiple windows are disabled (`UIApplicationSupportsMultipleScenes` off) because `AppNavigation`, `EditorShortcuts` and `BackupModel` are singletons; per-scene state comes first. Keyboard shortcuts (`AppCommands`, the editor's ⌘↩/Esc) are guarded by `ModalPresence`. Dropped images go through `ImageIntake`, the same processing as the picker; other dropped files become File blocks via `FileIntake`; non-file links are ignored, never fetched.

**Prompts and requests.** The rating prompt state is in UserDefaults (`RatingPrompt`): a due open is decided by the pure `Scheduler.countsAsDueOpen` inside `markViewed`, a Learn rating (`review`) counts too, and at 10 the prompt is asked once ever, from the main timeline. The reminder prompt is `ReminderPrompt` (key `reminderPromptAsked`), offered once ever after the editor closes on the first thought created there. Any test touching `RatingPrompt` or `ReminderPrompt` injects a throwaway suite (`RatingPrompt.throwaway()`), never the standard defaults. New-thought requests go through `AppNavigation.requestNewThought`, held as `pendingNewThought` until `RootTabView` consumes it (so it works on cold launch) and dropped while a sheet is up; App Intents only call it and open the editor empty.

**Network.** The app's only network calls are to our API (`transfer.thoughtreps.com/api/v1`) and presigned S3 (sync's debug exceptions: see the Sync Spec, "As built: client rules"). Feedback and creating or revoking an export link go through `AppAttestClient`; the public, unsigned export-link `status`/`claim`/`done` calls (`ExportLinkImportService`) and the presigned S3 `PUT`/`GET` of the encrypted export need no App Attest. Feedback never includes thought content; an export link upload does, but only as a file encrypted on device (AES-GCM) whose key never leaves the device except in the link's URL fragment. The share extension stays network-free. App Attest is unavailable in the simulator, so feedback and export links need a real device; Universal Links (`applinks:transfer.thoughtreps.com`) can't be tested there either.

**Blocks, images and backup.** A link block holds only `Block.linkedThoughtID` (see the Linked Thoughts Spec). A file block holds one `FileAsset` (any type, capped at 5 MB by `FileAttachment.maxBytes`, which the share extension shares; images aren't capped, they go through `ImageProcessor`) and opens in Quick Look, whose share button covers Save to Files and Open in; its filename is indexed in the search `titles` column, contents never. Old stored or exported kind "blurred" means blurred markdown (`migrateLegacyBlurredBlocks` at launch; import maps it). Images and files are `.externalStorage`, so large bytes sit in `.default_SUPPORT/_EXTERNAL_DATA` beside `default.store`; any file-level backup must include that folder. `ImageProcessor` downsizes to 2048 px HEIC (JPEG fallback) and strips metadata; the renderer resolves `img:` URLs only from the thought's own images. Backup import merges by thought id, group by group, each clock following the winning side (tag colors by `Tag.updatedAt`); tags are derived from the body. Importing from an export link downloads to a temp file and hands it to `BackupModel.beginImport`; opening a link only shows status and never claims, since claiming burns the one-time link. The uploaded file is the same backup, encrypted on device (`TRB1` + nonce + ciphertext + tag, AES-256-GCM); the key stays in the link's `#` fragment and, until expiry, in the Keychain so Settings can re-offer or revoke it. Known limit: ZIPFoundation rewrites the central directory per entry, so export time is quadratic in image count (~1 s at 4k images, ~100 s at 40k).

**Learn mode.** The growth math is pure, in `Scheduler.afterReview`: the first Got it waits 3 days (`Scheduler.learnFirstGapDays`; the thought's interval isn't used in Learn mode, and the editor shows "Back" with the due day in its place), then each Got it multiplies the last wait (`Thought.learnIntervalDays`) by 1.7, at least +1 day, capped at 365; Again is tomorrow and resets the wait. Learn state is in the backup.

**Timeline order.** The default Timeline freezes row order per snapshot (`TimelineOrder`), so an opened row stays put until the next refresh. Pinned thoughts aren't frozen but ordered by pin time (`stateChangedAt`, oldest first; `TimelineOrder.pinnedSorted`), so opening one never moves it.

**Themes.** Colors, fonts and card shapes come from `InkStyle.swift`, which reads `ThemeManager` (`AppTheme.swift`). Always-dark themes pin the windows' `overrideUserInterfaceStyle`, since `preferredColorScheme(nil)` can't reliably undo a forced scheme. The choice is in UserDefaults (no schema change). Premium themes are only an idea (TODO.md).

**Backup file layout.** `ThoughtReps/Services/Backup/` writes a zip whose first entry is a stored `mimetype` (`application/vnd.thoughtreps.export+zip`), then `manifest.json` (`formatVersion`, SHA-256 per entry), `tags.jsonl`, `thoughts.jsonl`, `images/<uuid>`, `files/<uuid>`. Import validates contents, not extension, and goes only through `ThoughtStore.importThoughts`. Record changes made before the first external TestFlight or App Store release don't bump `formatVersion`; from then on any record change does, and old versions stay importable.
