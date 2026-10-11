# Thought Reps — Launch Plan

Oct 5, 2026 · @Nick

What still has to happen to put Thought Reps 1.0 on the App Store, once search lands. The product spec (`Thought Reps for iPhone — Design Spec.md`) covers what the app does; this covers the business, store and release work around it.

## Launch definition

1.0 is ready to submit when:

- Search is merged and everything in **What ships in 1.0** below works on a real device.
- The open decisions below are made.
- The App Store listing, privacy answers and website pages are complete.
- A TestFlight build has been used for at least a week with no data-loss or crash issues.

## What ships in 1.0

**In:**

- Capture in Markdown, with images, blurred blocks and galleries.
- Resurfacing on an interval, with pin, archive and snooze.
- Tags with a timeline per tag.
- Search.
- Daily reminder.
- Share extension.
- `.thoughtreps` backup export and import, plus the one-time export link.
- In-app feedback.
- A one-time rating prompt.

**Moved to after launch:**

- **Study mode** (Again / Got it, growing intervals).
- **Markdown export.**
- **iCloud sync**, plus the existing "Later" items: Face ID lock, themes, and more block types.

The design spec still lists Study mode and Markdown export under "v1 release — must ship" (the Overview, the Study mode section and Milestones). Update it to match before launch so the two documents agree.

## Decisions needed

These block the store setup, so settle them first. Price is decided (see **Pricing** below).

1. **Subtitle.**
   - The name is **Thought Reps**. It was checked as available on Oct 5, 2026; reserve it by creating the App Store Connect record.
   - Search results show the name with the subtitle under it, so together they read as "Thought Reps: thought log + spaced repetition". Both are limited to 30 characters, so the full phrase can't be the name (it's 45).
   - Proposed subtitle: **Spaced repetition thought log** (29). The obvious "Thought log + spaced repetition" is 31, one character over the limit.
   - Words in the name and subtitle already count for search, so don't repeat them in the keywords field.
   - **Check the wording.** In 1.0, thoughts come back on a fixed interval; growing intervals arrive with Study mode. People who know Anki may expect growing intervals from "spaced repetition", so the description should say plainly how resurfacing works.
2. **Availability.**
   - Pick the territories (all is the default).
   - iPad is off; the app targets iPhone only.
   - Decide whether to allow it on Apple silicon Macs. It's on by default and the app hasn't been tested there.
3. **EU trader details.** A paid app makes you a trader under the Digital Services Act, which must be declared before the app can be listed in the EU.
   - The address, phone and email you give are shown publicly on the listing.
   - Decide which address and phone to publish, such as a business address or virtual office rather than a home address. The other option is leaving the EU out of the territories.

## Pricing

**Decided Oct 7, 2026: a paid download at $6.99, bought once** (changed from $9.99, decided Oct 5). The app is local-only and costs almost nothing to run, so there's no subscription and no in-app purchase in 1.0.

- **App Store Connect.**
  - Set the base price to $6.99 (US). Apple sets matching prices in other countries; review a few large markets and adjust if any look off.
  - Sign the Paid Apps agreement and complete tax forms and banking. Payouts can't start without them, and they can take a few days to be approved, so start early.
- **Family Sharing.** A paid app can usually be shared with up to five family members at no extra cost. Check what App Store Connect offers for it when setting the price, so it's a deliberate choice.
- **No trial.** A paid download can't be tried first, so the listing does the selling: screenshots, description and the landing page need to show the loop clearly. Refunds go through Apple, not us.
- **Website and listing.** Show the price wherever the app is offered ("$6.99, once. No subscription."). "Bought once, yours to keep" fits the local-first message.
- **Later.**
  - Post-launch features such as Study mode and Markdown export are free updates for buyers.
  - If iCloud sync ever needs a running cost, it could be an optional add-on then. Decide when sync is built, and keep it from taking away anything buyers already have.
  - Changing to free plus an unlock later is possible, but existing buyers would need to keep everything they paid for.

## Privacy

The app is local-first, but it isn't server-free: feedback and the export link both go to our API. Every public statement has to match that.

**Privacy policy page** (required URL), e.g. `thoughtreps.com/privacy`. It should say:

- Thoughts and images stay on the device. There's no account, no analytics and no tracking.
- **Feedback** sends:
  - the message and email address you enter;
  - the app version, iOS version and device model.

  It arrives as email at hello@thoughtreps.com and is kept as mail. Say how long it's kept and how to ask for deletion.
- **Export link** uploads the backup encrypted on the device; the key never reaches the server.
  - The server can't read it.
  - It's deleted on first download or after 24 hours.
- **App Attest.** Requests are signed with an Apple App Attest key, used only to prevent abuse and rate-limit per install.
- **Contact:** hello@thoughtreps.com.

**App Store privacy label** (proposed answers, to confirm):

| Data | Collected? | Purpose | Linked to user | Tracking |
| --- | --- | --- | --- | --- |
| Contact Info: email address | Yes, only when sending feedback | App functionality (support) | Yes | No |
| User Content: customer support (feedback message) | Yes | App functionality (support) | Yes | No |
| Diagnostics: other (app/iOS version, device model on feedback) | Yes | App functionality (support) | Yes | No |
| User Content: the export link file | Likely **not collected**: it's end-to-end encrypted and short-lived. Confirm against Apple's definition. | — | — | — |

**Privacy manifest.** Add `PrivacyInfo.xcprivacy` to both the app and the share extension. It declares:

- UserDefaults access (reason CA92.1).
- Any other required-reason APIs the code uses, such as file timestamps.
- The same collected data types as the label.

App Store Connect rejects uploads that use these APIs without a manifest.

**Export compliance.**
- The app uses encryption: HTTPS, plus AES-GCM through CryptoKit for the export link.
- Standard encryption from the OS normally qualifies for the exemption.
- Answer the questionnaire once, then set `ITSAppUsesNonExemptEncryption` in `project.yml` so builds stop asking.

## Website

The App Store needs a support URL and a privacy policy URL. A marketing URL is optional.

- **Add `/privacy` and `/support`.** Support can be short: the email, how to back up, and a few FAQ answers on what "due" means and restoring from a backup.
- **Fix copy that's no longer true.** The landing page currently says:
  - "There's no account and no server." Reword it, e.g. to "Your thoughts are never sent anywhere unless you choose to share them."
  - Export as "one Markdown file per thought". That's now post-launch.
- **App Store badge.** It's a non-clickable "coming soon" today. Link it once the App Store URL exists; the app ID is known as soon as the App Store Connect record is created.
- Deploy with `deploy-landing.sh` and record it in `INTEGRATIONS.md`.

## App Store listing

- **Category:** Productivity (primary), with Education or Lifestyle optional as secondary.
- **Age rating:** complete the questionnaire. There's no objectionable content and no web access; the expected rating is 4+.
- **Text:**
  - Description, plus promotional text (170 characters, editable without review).
  - Keywords (100 characters), e.g. notes, journal, ideas, review, markdown, reflect, remember, resurface. Leave out words already in the name or subtitle.
  - Release notes.
- **Screenshots:** 6.9" iPhone is required (1320×2868); Apple scales them down for smaller sizes. Plan 5 or 6:
  1. Timeline with due thoughts.
  2. Writing in Markdown with an image.
  3. Blurred block, before and after reveal.
  4. Tag timeline.
  5. Search.
  6. Reminder or snooze.

  Use realistic sample content, not the debug seed data. Framed with a caption per shot, matching the landing site's look.
- **App preview video:** optional, skip for 1.0.
- **App icon:** done (light, dark, tinted). Check it at small sizes and on the store page.

## App Review readiness

- **Review notes.** Explain:
  - There's no login.
  - Thoughts resurface after 7 days, so a fresh install shows an empty timeline. Say how to see the core loop: set a 1-day interval, or use snooze.
  - Feedback and the export link need network access and use App Attest.
- **Contact details** for the reviewer.
- **Permissions.** Camera, photos and notifications are each asked for in context and have clear purpose strings. The photo picker needs no permission.
- **Common rejection risks to check:**
  - Broken links in the listing.
  - The privacy policy not matching actual behavior.
  - Placeholder content or screenshots that don't show the real app.

## Release engineering

- **Version.** Set `MARKETING_VERSION` to `1.0.0` (it's `0.1.0` now) and bump `CURRENT_PROJECT_VERSION` on every upload.
- **Signing.** Register the production bundle ID, the share extension ID and the App Group. Then archive a Release build and upload it from Xcode.
- **Freeze the schema at the first TestFlight build.** After that upload, `SchemaV1` is frozen and any model change needs `SchemaV2` and a migration (see `CLAUDE.md`). Any last model changes must land before this point.
- **Data safety pass:**
  - Install a TestFlight build over an older build and check nothing is lost.
  - Check backup export and import round-trips on a device.
  - Run with a large library (thousands of thoughts, hundreds of images).
- **Real-device checks still pending:**
  - Feedback and export link through App Attest (marked pending in `INTEGRATIONS.md`).
  - Notification delivery.
  - Share extension.
- **Rating prompt.** It can't be verified in TestFlight because the prompt never shows there. Confirm in the 1.0 release that it fires once.
- **Accessibility pass.** Check VoiceOver labels on the timeline, editor and swipe actions, and check Dynamic Type at the largest sizes. These come up in reviews and in Apple featuring.

## TestFlight beta

1. **Internal testing** (up to 100 App Store Connect users, no review): you and anyone close, for a few days.
2. **External testing.** A public link or invites, after a light beta review. Aim for 10–30 people who'd actually use it, for about a week.
3. **Watch:**
   - Crashes in Xcode Organizer.
   - Feedback in the hello@ inbox.
   - Whether the 7-day loop makes sense to new users without explanation.
4. Fix anything that blocks launch, but don't change the schema unless it's essential, since it's frozen.

## Launch

- Submit with **manual release**, so you choose the day after approval.
- Use **phased release** for 1.0 or for updates. It only applies to automatic updates, so new installs get it immediately anyway.
- **On launch day:**
  - Link the App Store badge on the site.
  - Make the announcement on your chosen channels.
  - Fill in the App Store URL wherever "coming soon" appears.
- **For the first two weeks**, watch:
  - The feedback inbox and App Store reviews. Reply to reviews in App Store Connect.
  - Crash reports.
  - AWS costs for the Share stack. Usage should be tiny, but it's in a shared account.

## After launch

Ordered by likely demand. Revisit this once real feedback arrives.

1. Study mode: Again / Got it, with growing intervals.
2. Markdown export.
3. Remaining quick-capture items: Lock Screen and Control Center button, Shortcuts/Siri, widget.
4. iCloud sync. It needs `SchemaV2` thinking and CloudKit testing.
5. Face ID lock, themes and alternate icons.

## Checklist

- [ ] Search merged and tested
- [x] Price: $6.99, bought once
- [x] Name: Thought Reps (available)
- [ ] Decide: subtitle, availability, EU trader details
- [ ] Update design spec to move Study mode and Markdown export post-launch
- [ ] Privacy policy and support pages live; landing copy fixed; price shown on the site
- [ ] `PrivacyInfo.xcprivacy` (app and extension); `ITSAppUsesNonExemptEncryption` set
- [ ] App Store Connect record, bundle IDs, App Group, Paid Apps agreement, tax and banking (start early)
- [ ] Privacy label, age rating, export compliance answered
- [ ] Version 1.0.0; first TestFlight build uploaded; **schema frozen**
- [ ] Real-device checks: feedback, export link, notifications, share extension, large library, upgrade install
- [ ] Accessibility pass
- [ ] Internal, then external TestFlight (about 1 week)
- [ ] Screenshots, description, keywords, promo text, review notes
- [ ] Submit (manual release); approved
- [ ] Release; link badge on site; announce
