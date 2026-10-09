# App Store screenshots

The product page screenshots (Apple's "Screenshots" asset): real simulator captures of the app inside a faked ink-style phone, under a short headline and a supporting line. One folder per asset slot under `app-store-assets/`.

## Apple's specs

- 6.9" iPhone (the size App Store Connect requires; smaller sizes scale from it): 1320x2868, 1290x2796 or 1260x2736 portrait, .png/.jpg. No alpha channel; PNGs here are flattened to RGB.
- 1 to 10 screenshots per device size. The first three matter most: they show in search results and above the fold on the product page, so the strongest ideas come first.
- No video here (app previews are a separate slot).

## The set

Output is `static/<name>-1320x2868.png`. The copy lives in one place, `src/copy.js`. Claims are checked against the shipped app (default interval 7 days, 1d/3d/7d/30d chips plus more intervals and "Custom…", Markdown and gallery blocks, Active/Archived/All search, tag colors, one daily reminder at the chosen time); nothing from Study mode.

1. `01-timeline`: "Write it down. It comes back." / "Write a thought and it returns to your timeline in 7 days." The Timeline with a pinned thought and due thoughts.
2. `02-interval`: "Pick when you see it again." / "Bring it back in 1, 3, 7 or 30 days, or set your own." A thought's "Back in" bar with the more-intervals menu open.
3. `03-markdown-photos`: "Write in Markdown, add photos." / "Headings, lists, quotes and photo galleries in any thought." A thought with bold, italic, a list, a quote and a gallery.
4. `04-search`: "Find any thought in a second." / "Search everything you have written, active or archived." Search for "reflect", matches in bold.
5. `05-tags`: "Sort with #tags." / "Tag thoughts as you write, and give each tag its own color." The Tags list.
6. `06-reminders`: "Get a nudge, not a nag." / "One reminder a day at the time you pick, only when thoughts are due." Settings, Reminder section turned on.

The phone is drawn in CSS (ink border, hard offset shadow, a plain island); it is not Apple artwork. All six use one headline size, the largest at which the widest headline fits.

## How the captures work

`ThoughtRepsUITests/ScreenshotTests.swift` launches the app with the DEBUG-only `-screenshotMode` argument (`ThoughtReps/App/ScreenshotMode.swift`, compiled out of Release). In that mode the store and search index are in memory and filled by `ScreenshotSeed` through `ThoughtStore` (so the real store is never opened), the app is forced to light mode, the rating and reminder prompts are suppressed, no notification calls are made, the Developer settings section is hidden, and settings are overridden for that launch only (reminder on at 8:00 AM, 7-day default). The gallery images are drawn in code, so no photos or image files are bundled. Each test attaches one PNG of the whole screen (1320x2868); `gen.mjs` exports them from the `.xcresult` into `raw/`.

The tests live in their own scheme, `ThoughtRepsScreenshots`, so a normal `xcodebuild test` of `ThoughtReps` does not run them. To change a screen, edit the seed or the test, re-run `--capture`, and commit the new `raw/` files.

## Regenerate

```
node app-store-assets/Screenshots/gen.mjs                 # composite static/ from the committed raw/ (seconds, no Xcode)
node app-store-assets/Screenshots/gen.mjs 04-search       # only outputs whose name contains the argument
node app-store-assets/Screenshots/gen.mjs --capture       # re-capture raw/ in the simulator first (about three minutes), then composite
```

`--capture` creates a dedicated simulator named "ThoughtReps Screenshots" from the iPhone 18 Pro Max device type if it is missing (so the shared simulators another session may be using are left alone), boots it, overrides the status bar (9:41, full battery, Wi-Fi, 4 bars), runs `xcodegen` and `xcodebuild test -scheme ThoughtRepsScreenshots -only-testing:ThoughtRepsUITests`, and exports the attachments. It needs Xcode, xcodegen and `Config/Local.xcconfig`. If the Mac updates to a runtime with a different screen size, the raw captures are no longer 1320x2868; check the device type.

Compositing needs ffmpeg and Playwright's Chromium (`chromium-1243`); first run: `npx playwright@1.63 install chromium`. Playwright is not a repo dependency. Brand CSS/JS and the Archivo font come from `../Header/src` and `../SearchResults/src` by relative path; nothing is copied. Open `preview.html` to see all six side by side and the first three at about the size they show in search results.

## Upload

App Store Connect, the version's product page, 6.9" iPhone screenshots: drag in `static/*.png` in numeric order. Other iPhone sizes scale from the 6.9" set.
