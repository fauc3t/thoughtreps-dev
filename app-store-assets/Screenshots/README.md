# App Store screenshots

The product page screenshots (Apple's "Screenshots" asset): real simulator captures of the app inside a faked ink-style phone, under a short headline and a supporting line. One folder per asset slot under `app-store-assets/`.

## Apple's specs

- 6.9" iPhone (the size App Store Connect requires; smaller sizes scale from it): 1320x2868, 1290x2796 or 1260x2736 portrait, .png/.jpg. No alpha channel; PNGs here are flattened to RGB.
- 1 to 10 screenshots per device size. The first three matter most: they show in search results and above the fold on the product page, so the strongest ideas come first.
- No video here (app previews are a separate slot).

## The set

Output is `static/<name>-1320x2868.png`. The copy and the set live in one place, `src/copy.js` (which captures each output shows, and its layout). Claims are checked against the shipped app (default interval 7 days, 1d/3d/7d/30d chips plus more intervals and "Custom…", Markdown and gallery blocks, blurred blocks, Learn mode's Again / Got it and its growing waits (7, 12, 20 days), six free themes, Active/Archived/All search, tag colors, one daily reminder at the chosen time); nothing from the unbuilt rest of Study mode. The sample content reads like a commonplace book (a quote with its source, a book note, a sermon and a podcast takeaway, a lesson, a poem to memorize), and any quote or poem in it must be public domain.

1. `01-timeline`: "Write it down. It comes back." / "A commonplace book that brings every quote and idea back in 7 days." The Timeline with a pinned thought and four due thoughts, one of them in Learn mode (the seed keeps the list ending above the + button).
2. `02-blurred`: "Hide the answer. Test yourself." / "Blur part of any thought until you tap to reveal it." Two phones, a thought with a blurred "Answer" block before and after the tap (`02-blurred-before`, `02-blurred-after`).
3. `03-learn`: "Learn it for good." / "Tap Again or Got it. Each Got it waits longer: 7, 12, 20 days." A due Learn thought (two Dickinson lines to memorize) with its blurred lines revealed above Again ("Tomorrow") and Got it ("In 12 days"; the seed sets its last wait to 7).
4. `04-themes`: "Six looks, all included." / "Ink, Library, Midnight, Garden, Terminal and Pop." Six phones in a cascade, the same thought in each theme, Ink in front (`04-themes-<theme>`); the supporting line names them, so the phones carry no labels.
5. `05-interval`: "Pick when you see it again." / "Bring it back in 1, 3, 7 or 30 days, or set your own." A thought with its "Back in" bar: 1d, 3d, 7d (selected), 30d and the more-intervals chip.
6. `06-markdown-photos`: "Write in Markdown, add photos." / "Headings, lists, quotes and photo galleries in any thought." A thought with bold, italic, a list, a quote and a gallery (not due, so the test opens it from its tag).
7. `07-search`: "Find any thought in a second." / "Search every note and journal entry, active or archived." Search for "reflect", matches in bold.
8. `08-tags`: "Sort with #tags." / "Tag thoughts as you write, and give each tag its own color." The Tags list.
9. `09-reminders`: "Get a nudge, not a nag." / "One reminder a day at the time you pick, only when thoughts are due." The reminder notification on the Lock Screen ("Thought Reps", "4 thoughts are back today").

The first three are the strongest ideas: the loop, self-testing with a blurred answer, and Learn mode. One supporting line per shot may carry a search word (commonplace book, quote, idea, note, journal) where it reads naturally. The phone is drawn in CSS (ink border, hard offset shadow, a plain island); it is not Apple artwork. All nine use one headline size, the largest at which the widest headline fits.

## How the captures work

`ThoughtRepsUITests/ScreenshotTests.swift` launches the app with the DEBUG-only `-screenshotMode` argument (`ThoughtReps/App/ScreenshotMode.swift`, compiled out of Release). In that mode the store and search index are in memory and filled by `ScreenshotSeed` through `ThoughtStore` (so the real store is never opened), the app is forced to the Ink theme in light mode (the extra `-screenshotTheme <name>` argument picks another theme for that launch; always-dark themes stay dark), the rating and reminder prompts are suppressed, no notification calls are made, the Developer settings section and the export-link refresh are skipped, and settings are overridden for that launch only (reminder on at 8:00 AM, 7-day default). The gallery images are drawn in code, so no photos or image files are bundled. The reminder shot is the one exception to "no side effects": the extra `-screenshotReminder` argument calls `NotificationScheduler.sendTestReminder` at launch, so the simulator is asked for notification permission (the UI test taps Allow), then the device is locked and the notification captured on the Lock Screen. The real store is still never touched; only run `--capture` on the dedicated simulator. The Lock Screen clock reads 9:41 and the date "Sat Jan 1" because of the status bar override, and the notification says "2m ago".

Each capture is one PNG of the whole screen (1320x2868); most tests attach one, the blurred test two and the themes test six; `gen.mjs` exports them from the `.xcresult` into `raw/`.

The tests live in their own scheme, `ThoughtRepsScreenshots`, so a normal `xcodebuild test` of `ThoughtReps` does not run them. To change a screen, edit the seed or the test, re-run `--capture`, and commit the new `raw/` files.

## Regenerate

```
node app-store-assets/Screenshots/gen.mjs                 # composite static/ from the committed raw/ (seconds, no Xcode)
node app-store-assets/Screenshots/gen.mjs 07-search       # only outputs whose name contains the argument
node app-store-assets/Screenshots/gen.mjs --capture       # re-capture raw/ in the simulator first (about three minutes), then composite
```

`--capture` creates a dedicated simulator named "ThoughtReps Screenshots" from the iPhone 18 Pro Max device type if it is missing (so the shared simulators another session may be using are left alone), boots it, overrides the status bar (9:41, full battery, Wi-Fi, 4 bars), runs `xcodegen` and `xcodebuild test -scheme ThoughtRepsScreenshots -only-testing:ThoughtRepsUITests`, and exports the attachments. If that device type is not installed it stops with an error; update Xcode or point `DEVICE_TYPE` in `gen.mjs` at another 6.9" iPhone. It needs Xcode, xcodegen and `Config/Local.xcconfig`. If the Mac updates to a runtime with a different screen size, the raw captures are no longer 1320x2868; check the device type.

Compositing needs ffmpeg and Playwright's Chromium (`chromium-1243`); first run: `npx playwright@1.63 install chromium`. Playwright is not a repo dependency. Brand CSS/JS and the Archivo font come from `../Header/src` and `../SearchResults/src` by relative path; nothing is copied. Open `preview.html` to see the whole set side by side and the first three at about the size they show in search results.

## Upload

App Store Connect, the version's product page, 6.9" iPhone screenshots: drag in `static/*.png` in numeric order. Other iPhone sizes scale from the 6.9" set.
