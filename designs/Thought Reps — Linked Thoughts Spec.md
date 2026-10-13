# Thought Reps — Linked Thoughts Spec

Status: draft, 2026-10-13. Not built. **In 1.0.** It changes the model and the backup record, so it must land before the schema freezes (section 9).

Linked thoughts let you add another thought to a thought as a block. The block shows that thought as a small card, and tapping the card opens it. Following cards from thought to thought gives a lightweight mind map: one thought that comes due can lead you through others if you want to walk them.

## Decisions

These were settled with the user on 2026-10-13:

1. **Following a link doesn't change the due date.** Opening a thought from a link card never requeues it. It counts as a view (`viewCount` and `lastViewedAt`), but nothing else (section 4).
2. **Linked thoughts don't come due together.** Only the thought that's due resurfaces, and walking its links is up to you.
3. **Missing targets:** if the linked thought is deleted, the card says so and can be removed. If it's archived, the card still shows, dimmed.
4. **One level only.** The card shows the linked thought itself (title and a preview), never that thought's blocks or links. You can keep walking by opening the card.
5. **Picking a thought is a search.** A sheet searches titles and content and shows enough of each result to recognize it.

Out of scope for 1.0:
- a spatial map or graph view
- `[[` autocomplete in the Markdown editor
- inline links inside Markdown text
- linking from the share extension

## 1. What the user sees

**In a thought:** a link block renders as a compact card in the block list, in block order like any other block.
- **Contents:** the linked thought's title (from `ThoughtTitleSplit`, falling back to the first line of plain text), two lines of preview, and its tag chips.
- **Style:** a small link glyph (Lucide `link-2` on the web, the matching SF Symbol in the app) marks it as a link and not the thought's own content. Ink tokens only.
- **Archived target:** the card is dimmed, with an "Archived" label, and still opens.
- **Deleted or missing target:** the card says "This thought was deleted", has no preview, and doesn't open. In the editor it has a remove button.

**Linked from:** at the bottom of a thought's detail screen, a "Linked from" section lists the thoughts that link to it, as the same compact cards. It's hidden when there are none. Without it a link only goes one way, and the mind-map feel needs both.

**Walking links:**
- **iPhone:** tapping a card pushes the linked thought onto the current stack, so Back returns to where you came from.
- **iPad split view:** it pushes onto the detail column's stack and leaves the selection alone. Changing the selection would count as a new open.
- **Further links:** you can follow links from a linked thought too. Every step is a push.

**Adding a link:** the editor's add-block menu gets **Linked thought**. It opens the picker sheet (section 5). The chosen thought becomes a link block at the end, and it reorders and removes like other blocks. A link can be added to a new thought before its first save.

## 2. Data model (SchemaV1, edited in place)

- **New kind:** `BlockKind.thoughtLink`, raw value `"thoughtLink"`, label "Linked thought".
- **New field:** `Block.linkedThoughtID: UUID? = nil`. It has a default and no relationship, so it stays CloudKit-compatible. It's a plain id rather than a SwiftData relationship for these reasons:
  - Deleting the target never has to touch the thoughts that link to it.
  - Sync and import can carry a link to a thought that isn't there yet.
  - There's no inverse to keep consistent.
- **Field rules:** a link block has empty `content`, no images, `isBlurred == false` and a nil `title`. Its `linkedThoughtID` is set, and it never equals its own thought's id.
- **Duplicates:** at most one link block per target within a thought. The picker hides targets that are already linked.
- **Change clock:** adding, removing or reordering a link is a content change and bumps `updatedAt`. The linked thought isn't touched.
- **Deleting a target:** nothing else is written. Links to it dangle on purpose, and the `Tombstone` from `ThoughtStore.delete` tells "deleted" apart from "not here" (section 3).
- **Fixture:** regenerate `ThoughtRepsTests/Fixtures/default.store` with `FixtureGenerator`.

## 3. Resolving and querying (scale rules)

- **Card targets:** one query per displayed thought, not per card. Collect the thought's `linkedThoughtID`s and fetch them with a single `#Predicate { ids.contains($0.id) }`. Missing ids render as deleted. This is a reusable builder in `ThoughtCounts`, tested against an in-memory container.
- **Linked from:** one `Block` fetch with `kindRaw == "thoughtLink" && linkedThoughtID == id`, mapped to the blocks' thoughts. Archived sources are left out, and `fetchLimit` caps it at 50 with "and N more" from a `fetchCount`. Also a `ThoughtCounts` builder, tested.
- **Deleted vs. missing:** a tombstone lookup by id (`fetchLimit` 1) is optional polish. A missing target and a deleted one can share the "deleted" card in 1.0.
- **Refresh:** cards refresh when the parent view refreshes. A stale title is acceptable until then.

## 4. Opening from a link: no view, no requeue

- **Route:** a link push uses a new route, `AppRoute.linkedThought(Thought)`. It renders `ThoughtDetailView` in a "visit" mode that calls a new `ThoughtStore.recordVisit(_:now:)` instead of `markViewed`.
  - **Recorded:** `recordVisit` bumps `viewCount` and sets `lastViewedAt`. The backup rule needs `lastViewedAt` whenever `viewCount > 0`.
  - **Unchanged:** `nextDueAt`, the interval, the Learn wait, and `scheduleChangedAt`. View counters have no change clock, so no clock moves.
  - **Rating prompt:** it doesn't count the visit, because that prompt counts due opens that requeue.
  - **Timeline:** the visited thought shows on the timeline until the next refresh, as any open thought does. Going back to the timeline refreshes it.
- **Learn mode:** a Learn thought opened from a link still shows **Again** / **Got it** if it's due. Rating is an explicit action, so it applies as usual.
- **Everything else works as normal from a visit:** editing, snooze, pin, archive and delete. Each of these is an explicit write.
- **Fold carry:** `LayoutCarry` already maps `AppRoute` values, so linked routes need no extra mapping. The remounted visit must not count twice, so `ViewHandoff` covers `recordVisit` exactly as it covers `markViewed`. Add tests that a `.linkedThought` route carries and isn't counted twice.

## 5. The picker

- **Search:** a sheet with a search field backed by `SearchIndex.search` (FTS5, active scope) over body, block text, titles and tags.
- **Results:** each row shows a title, a two-line snippet and tags, and resolves the matched ids with one batched fetch.
- **Empty query:** shows recently updated thoughts (`fetchLimit` 20, sorted by `updatedAt`) so linking a thought you just wrote is one tap.
- **Excluded from results:** the thought being edited, thoughts already linked from it, and archived thoughts. Archived thoughts can't be linked in 1.0, but existing links to a thought that is later archived stay.
- **No results:** the sheet says "No thoughts match".
- **Search index unavailable:** if the index is still rebuilding at launch, the sheet falls back to recent thoughts with a "Search is catching up" note. The existing search UI handles this case the same way.

## 6. Search index

- **Nothing new is indexed.** A link block adds no text to its thought's `SearchDocument`: the linked thought's words belong to that thought, and indexing them twice would make every search return the hub too.
- **Reindex trigger:** adding or removing a link bumps `updatedAt`, so the existing reindex path runs anyway. That's harmless, and nothing new is submitted.

## 7. Backup format

- **Record change:** `BlockRecord` gains `linkedThoughtID: UUID?`, decoded with `decodeIfPresent` so older archives still decode.
- **No `formatVersion` bump:** nothing has shipped yet, so CLAUDE.md's pre-ship exception applies. From the first external release, a change like this would need `BackupFormatV2`.
- **Validation** (`ThoughtRecord.isImportable`):
  - A `thoughtLink` block needs `linkedThoughtID`, empty content, no images, not blurred, and not a link to itself.
  - Non-link blocks must have no `linkedThoughtID`.
  - Duplicate targets within a thought are invalid.
- **Import:** a link to a thought that's in neither the file nor the store is kept and renders as deleted. Rejecting the whole thought would lose its own content. Merging needs no change: link blocks belong to the content group and follow `updatedAt`.
- **Export link:** the encrypted export link carries the same file, so it needs nothing extra.

## 8. Integrity and tests

**`IntegrityChecker` additions:**
- every `thoughtLink` block has a `linkedThoughtID` that isn't its own thought's id
- link blocks have empty content, no images and no blur
- non-link blocks have no `linkedThoughtID`
- no duplicate targets within a thought
- dangling links are allowed

**Randomized operation tests:** add "add link", "remove link" and "delete a link target", with save failures injected. The store must stay free of violations, and deleting a target must never touch the thoughts that link to it.

**Tests** (Swift Testing, in-memory container):
- card resolution with present, archived and missing targets, in one fetch
- the "Linked from" builder: excludes archived sources, respects `fetchLimit`, and its count matches
- a visit bumps `viewCount` and `lastViewedAt` and never changes `nextDueAt`, the schedule clock, the Learn wait or the rating prompt counter (throwaway `RatingPrompt` suite)
- store writes: adding a link bumps `updatedAt` only; self-links and duplicates are rejected
- backup round trip with links; validation failures; importing a dangling link; an old archive without the field still decodes
- `LayoutCarry` with a `.linkedThought` route
- picker filtering: self, already linked, archived

## 9. Schema freeze and timing

Decided 2026-10-13: edit `SchemaV1` in place, no migration. No external build has shipped. After the change, internal testers delete and reinstall the app.

## 10. Docs and launch surfaces

- **Help center:** a new `help.ts` article, "Link thoughts into a mind map" (section 12), covering adding a link, walking links, "Linked from", that following a link doesn't move its due date, and what deleted and archived links look like. Add a `HelpExamples.tsx` mockup with the real labels. Link it to and from the blocks article and "What opening a thought does".
- **CLAUDE.md:**
  - extend the v1 blocks decision to name `thoughtLink`
  - note that a visit from a link calls `recordVisit` (view count only, no requeue), under "Opening a thought requeues it"
  - add the link resolution builders to the scale rule's list
- **Landing page:** optional, one line in the feature grid. Only after it ships in a build.

## 11. Build plan (fellowship)

Each step lands as its own push through the usual pipeline (dev agent, then reviewer, then docs):

1. **Model, store, backup and integrity:** `BlockKind`, the `Block` field, `ThoughtStore` add, remove and reorder, the `BlockRecord` and validation, the `IntegrityChecker` and randomized ops, and the fixture regenerated.
2. **Rendering and walking:** the link card, the batched resolution, the `.linkedThought` route and visit mode, "Linked from", and the split detail stack.
3. **Editor and picker:** the add-block menu entry, the search sheet, removing deleted links.
4. **Docs:** the help article, its mockup and CLAUDE.md.

## 12. Naming

- **In the app:** "Linked thought" (the add-block menu, `BlockKind.label`) and "Linked from". These are plain and describe the action. "Mapped" doesn't say what tapping does, and there's no map view to back it up.
- **For search:** the help article title and the landing page carry the phrase people actually search for: "Link thoughts into a mind map". The article body uses "linked notes" and "connect ideas" once each. It must not suggest a visual map view, since none ships.

## Resolved (2026-10-13)

1. A visit bumps `viewCount` and `lastViewedAt` but never the due date (section 4).
2. "Linked from" ships in 1.0.
3. Naming: "Linked thought" in the app, "mind map" in help and SEO copy (section 12).
4. Archived thoughts can't be linked from the picker for now.
