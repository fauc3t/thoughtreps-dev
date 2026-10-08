# TODOs

- transfer-web/index.html:14 — add the Smart App Banner (`apple-itunes-app`) once the App Store ID exists; must be added at runtime from `main.tsx` because `app-argument` needs the `#fragment`
- After the launch email (and TestFlight invites), delete all WaitlistTable rows and the [Waitlist] notification emails; the privacy policy promises it.

## Backlog

- Focus mode (after 1.0): work through the due thoughts one at a time as a card deck, with "Tomorrow" and "Next thought" buttons. Mockup: "4 · Deck" on the redesign canvas (https://claude.ai/artifact/JZqwkCVcyZMhhttR3Bm5nm). Decide how it relates to Study mode (Again / Got it) first: opening a thought requeues it, and CLAUDE.md says not to change that outside the Study mode work.
- Timeline mode (after 1.0): one continuous scroll through every thought ever written, newest first by creation date and grouped by day or month, so you can read the stream of thoughts as it happened. It ignores due dates (archived thoughts are an open question). It has to load in pages (`fetchLimit` plus `fetchOffset` or a date cursor), never as one `@Query` array, because of the "Assume hundreds of thousands of thoughts" rule in CLAUDE.md.
- Kindle highlights import (after 1.0): import the `My Clippings.txt` file a Kindle keeps in its `documents` folder (title and author, location and date, highlight, `==========` separator), parsed on device and opened from Files or the share sheet. It also catches sideloaded docs and highlights past the publisher's export cap. Never scrape `read.amazon.com/notebook`: it breaks the "only network calls are to our API" rule and is fragile. Open questions: one thought per highlight or per book; dedupe on re-import (the file only grows, so it needs a stable key such as a hash of book, location and text); tagging (`#kindle`, the book title); and whether it goes through `ThoughtStore.importThoughts` or `InboxImporter`. Files can hold thousands of entries. Maybe later: the Kindle app's "Export notes" email (HTML/CSV).
- Purchasable themes (idea, after 1.0): sell optional themes (colors, fonts, card style) as in-app purchases on top of the $6.99 app, so people can change how the app feels. Open questions: one-off per theme or a single "all themes" unlock; whether any come free; how far a theme reaches (just colors, or fonts and card shapes too, beyond the "Ink, lighter" redesign tokens); dark mode for each one; and the App Icon (alternate icons could ship with a theme). StoreKit 2 is Apple's network call, not ours, but check the privacy manifests, privacy policy and App Store privacy answers anyway. The theme choice would live in UserDefaults (no schema change), and the help center needs an article.

### Audit follow-ups (2026-10-07)

- Per-route API throttles and Lambda reserved concurrency (account shared with strands).
- Revoke during upload leaves the S3 object until the lifecycle expires it.
- Mail bucket: replace `grantRead` with narrow `GetObject`; add `enforceSSL`.
- Log retention and API access logs.
- Keychain save via `SecItemUpdate`.
- https check on the export download URL.
- 44pt touch targets for interval and tag chips.
- Dead code: `ThoughtStore.syncTags(for:)`, `SearchIndex.flush`, `InkStyle` ShapeStyle shorthands, `ExportLinkCrypto.encrypt` (test-only).
- Split `ThoughtStore.swift`, the `MarkdownTextView` Coordinator and `EditorView`.
- Dedupe `TagRow`/`UntaggedRow`, the interval menu, `theme.js`.
- In-app font licenses screen (OFL for Archivo and Paper Mono).
