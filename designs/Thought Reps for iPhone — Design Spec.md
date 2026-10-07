# Thought Reps for iPhone — Design Spec

Oct 4, 2026 · @Nick

## Overview & goals

Thought Reps is a native iPhone app for capturing thoughts and having them come back on a schedule, so ideas get revisited instead of forgotten. Everything lives on the device; no account or server is required.

Goals for v1:

- Capture a thought in under 5 seconds from launch, written in Markdown with images.
- Resurface each thought on a timeline after its interval (default 7 days); viewing it re-queues it.
- Pin thoughts to keep them always visible; archive thoughts to retire them.
- Organize with inline `#hashtags`, with a timeline per tag.
- Attach extra blocks to a thought, starting with blurred (tap-to-reveal) text.

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
- Blurred blocks act as the answer to recall before revealing.
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
| kind | String | `blurred` in v1; `quote`, `link`, `checklist` later |
| content | String | Markdown or plain text, per kind |
| title | String? | Optional label, e.g. "Answer" |
| order | Int | Position under the thought |
| thought | Thought? | Inverse |

**ImageAsset**

| Field | Type | Notes |
| --- | --- | --- |
| id | UUID |  |
| filename | String | File in `Images/<thoughtID>/` |
| width, height | Int | For layout before load |
| thought | Thought? | Inverse |

Images are stored as files in the app's Application Support folder, not inside the database, and referenced from Markdown as `![](img:<id>)`. Settings (default interval, notification time) live in `UserDefaults`.

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
3. Type, optionally add images or a blurred block.
4. Save. The thought is waiting and first comes due after its interval.

Review flow:

1. Open the app; due thoughts are on the Timeline.
2. Tap a card to read it. The view is recorded.
3. Go back; the card is gone until its next due date, unless pinned.
4. Or swipe to archive, pin or snooze without opening.

Empty states matter here: an empty Timeline says what is coming next ("3 thoughts come back tomorrow") rather than looking broken.

## Content: Markdown, images & blocks

Thought bodies are GitHub-flavored Markdown rendered with a third-party SwiftUI library, because Apple's built-in Markdown support only covers inline styles. Blocks are separate records rendered under the body.

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
| Blurred text | Content shown with a heavy blur and an optional title; tap to reveal, tap again to hide. Reveal state resets each time the thought opens. | v1 |
| Quote / source | A citation with author and link | Later |
| Checklist | Tickable items whose state persists | Later |
| Link preview | URL with a fetched title and image | Later |

Blocks are added from the editor's **Add block** menu, reordered by drag, and each block kind is one SwiftUI view plus one case in a `BlockKind` enum, so new kinds stay small.

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
- **Services**: `TagParser`, `ImageStore` (files on disk), `NotificationScheduler`, `Exporter`.

**Repo layout**

```
ThoughtReps/
├── ThoughtReps.xcodeproj
├── ThoughtReps/
│   ├── App/            ThoughtRepsApp.swift, RootTabView.swift
│   ├── Models/         Thought, Tag, Block, ImageAsset
│   ├── Scheduler/      Scheduler.swift, IntervalMode.swift
│   ├── Stores/         ThoughtStore.swift, TagStore.swift
│   ├── Services/       TagParser, ImageStore, NotificationScheduler, Exporter
│   ├── Features/
│   │   ├── Timeline/   TimelineView, ThoughtCard
│   │   ├── Thought/    ThoughtDetailView, ThoughtRenderer
│   │   ├── Editor/     EditorView, FormatBar, BlockEditor
│   │   ├── Blocks/     BlockKind, BlurredBlockView
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

All three are local-first: notifications are scheduled on-device, backup is a file you own, and sync is optional iCloud.

**Notifications (v1)**

- One daily reminder at a user-set time (default 8:00 AM): "4 thoughts are back today."
- Rescheduled whenever the app goes to the background, using the count of thoughts due by that time.
- No reminder when nothing is due. Off until the user grants permission from Settings.

**Export and import (v1)**

- Export writes a `.thoughtreps` file (a zip, UTType `com.thoughtreps.export`) with `manifest.json`, `tags.jsonl`, `thoughts.jsonl` and `images/<uuid>`, shared via the system share sheet to Files, AirDrop or iCloud Drive.
- Import reads the same format (also via Open in Thought Reps from Files or AirDrop) and merges by `id`, keeping the newer `updatedAt`.
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

1. **Skeleton — done.** Repo, models, Scheduler with tests, timeline, thought view with view-to-requeue, pin, archive, snooze, editor with blurred blocks, tags and tag timelines, archive, settings, sample data.
2. **v1 release — must ship.**
    - Backup and export/import (zip of JSON + images; Markdown export).
    - Daily reminder notification.
    - Search across bodies and blocks.
    - Markdown renderer (MarkdownUI vs Textual spike) and images.
    - Study mode: Again / Got it, growing intervals, blurred blocks as answers.
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
- [ ] Any block types from the original app beyond blurred text that v1 should include?
