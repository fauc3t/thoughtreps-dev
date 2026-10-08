# App Store search results

The Search Results creative (Apple's "Search Results" asset): a still or a muted looping video shown in search next to the app's icon, name and Get button.

## Apple's specs

- Image: 3:2 from 1920x1280 up to 3840x2560, or 16:9 at 5244x2950 (.jpeg/.jpg/.png). No alpha channel; PNGs here are flattened to RGB.
- Video: same ratios and sizes, 30 or 60 fps, 5-30 s, .mov/.m4v/.mp4. It plays muted (it can't be unmuted in search) and loops continuously.
- Guidance: "state the obvious". The purpose of the app should be clear at a glance. It shows small, so use big type and big shapes, no tiny text, and keep key content centered, away from the edges.

## Options

Each is rendered at 3840x2560 (3:2) and 5244x2950 (16:9), as a PNG in `static/` and a 30 fps, 12 s seamless-loop H.264 MP4 in `motion/`.

- A timeline + headline: the Header timeline drift under "Write it down. It comes back."
- B timeline only: the same drift with the cards scaled up to fill the frame.
- C in the app: the app's Timeline screen in a plain ink-style phone frame, with the headline beside it. The Due list is ordered like the app (sorted by `nextDueAt`, most overdue on top). Every 2.4 s the top thought is read and leaves, the rest age a day and move up ("due 3d ago", "due 2d ago", "due 1d ago"), and a new "due today" thought enters at the bottom with the loop badge. Labels follow `ThoughtCard.swift`; all copy comes from `Hero.tsx` and `HelpExamples.tsx`. The phone is not Apple artwork.

The 3:2 and 16:9 renders are laid out separately (not a crop), so each keeps its content centered.

Video encoding: libx264 High, CRF 18, yuv420p, bt709, no audio, `-level 6.0`. Both sizes fit level 6.0 at 30 fps (MaxFS 139,264 macroblocks, MaxMBPS 4,177,920; 5244x2950 is 60,680 MBs, about 1.8M MB/s). Some hardware decoders and older players don't support level 6.x, and App Store Connect's acceptance of it is still to be confirmed with a test upload. If it is rejected, re-encode as HEVC: `ffmpeg -i in.mp4 -c:v libx265 -tag:v hvc1 -crf 20 -pix_fmt yuv420p -an out.mov`.

## Regenerate

```
node app-store-assets/SearchResults/gen.mjs            # everything (about 7 minutes)
node app-store-assets/SearchResults/gen.mjs C-in       # only outputs whose name contains the argument
node app-store-assets/SearchResults/gen.mjs --still    # PNGs only
```

Needs ffmpeg and Playwright's Chromium (`chromium-1243`); first run: `npx playwright@1.63 install chromium`. Playwright is not a repo dependency. Brand CSS/JS, the Archivo font and the timeline drift come from `../Header/src` (`shared.css`, `shared.js`, `timeline.css`, `timeline-core.js`); nothing is copied. Open `preview.html` to see every output plus a mock search card at about real size.

## Upload

App Store Connect, the version's product page, search results: upload one `motion/*.mp4` or one `static/*.png`. Recommended: `motion/A-timeline-headline-3840x2560.mp4` (readable headline at small size), or the PNG of the same name as the still.
