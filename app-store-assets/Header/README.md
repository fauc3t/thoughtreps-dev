# App Store header

The product page header (Apple's "Header" creative asset). One folder per asset slot under `app-store-assets/`.

## Apple's specs

- Image: 21:9 at 3840x1646 (.jpeg/.jpg/.png) or 16:9 at 5244x2950 (.png only). No alpha channel; PNGs here are flattened to RGB.
- Video: 21:9 at 3840x1646 only, 30 or 60 fps, 5-30 s, .mov/.m4v/.mp4. Muted, loops continuously.
- Apple publishes no safe zones. Keep one clear idea near the center; the store may overlay the icon, name and Get button, so the art stays out of the bottom ~20% and outer ~12% each side. `preview.html` draws that safe zone with an extra 8% top margin (our own choice, not Apple's). The 16:9 renders are the same 21:9 scene with more background above and below.

## Options

Static (each at 3840x1646 and 5244x2950, in `static/`):

- A headline: "Write it down. It comes back." with the loop mark and app icon. `A-headline-dark` is a dark variant.
- B card stack: the landing hero's three-note deck, no text outside the cards.
- C timeline: thoughts along a week-by-week line, one rising back up.

Motion (3840x1646, 30 fps, 12 s seamless loop, H.264, no audio, in `motion/`):

- A card swing: the hero deck animation, three swings per loop.
- B timeline drift: the timeline drifts left while each thought comes back up in turn.

## Regenerate

```
node app-store-assets/Header/gen.mjs            # everything (about a minute)
node app-store-assets/Header/gen.mjs B-card     # only outputs whose name contains the argument
```

The timeline scene (`src/timeline-core.js`, `src/timeline.css`) is shared: `../SearchResults` imports it by relative path, so changes there affect both slots.

Needs ffmpeg and Playwright's Chromium (`chromium-1243`). First run on a machine: `npx playwright@1.63 install chromium`. Playwright is not a repo dependency; `gen.mjs` runs it through `npx playwright@1.63`. Sources are in `src/`; each exposes `render(t)` and the motion frames are screenshotted one by one, so output is deterministic. Open `preview.html` to see every output with the 21:9 crop and safe zone.

## Upload

App Store Connect, the version's product page: upload one of `static/*-5244x2950.png` or `static/*-3840x1646.png` as the header image, or one `motion/*.mp4` as the header video (21:9 only). Fonts are Archivo (copied to `src/fonts/`) and Paper Mono (from `site-landing/src/fonts/`).
