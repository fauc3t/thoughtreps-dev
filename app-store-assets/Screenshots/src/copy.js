// All screenshot copy, in App Store order. `name` is the output. `cards` are the app captures it shows, back to front,
// each a crop of one raw/ capture (set by ThoughtRepsUITests/ScreenshotTests.swift) in a Pop card with a hard shadow:
//   raw            the capture's name in raw/
//   top, bottom    the raw rows shown (raw px; 330-2600 is a thought's content without the nav buttons and tab bar)
//   pad            blank raw px added below the crop, in `bg` (default the Ink paper, white)
//   x, y, s, rot   the card's left and top on the 1320x2868 canvas, its scale (raw px to canvas px) and its tilt in degrees
// A card whose bottom runs past the canvas shows only the top of the screen. `<mark>` highlights a word; `<loop></loop>`
// draws the loop mark. Lines of a headline are separated by <br>. Loaded by shot.html, preview.html and gen.mjs.
// The frame is the Pop theme (colors, Futura, Avenir Next); the captures inside are the Ink theme, except the themes shot.
// Claims are checked against the shipped app: default interval 7 days (Settings), quick intervals 1d/3d/7d/30d plus
// "…" with more and "Custom…" (ThoughtDetailView), Markdown, gallery, file and link blocks, blurred blocks hidden until
// tapped ("Blur until tapped"), linked thoughts open on tap (LinkedThoughtCard), six free themes (AppTheme), search
// scopes Active/Archived/All, tag colors (Change Color), one reminder a day at the chosen time (SettingsView,
// ReminderPlanner). The first three show in search results. One supporting line per shot may carry a search word
// (commonplace book, quote, idea, note, journal) where it reads naturally.
// Back to front: light and dark alternate, and Ink, the default, is in front.
const CASCADE = ['pop', 'terminal', 'garden', 'midnight', 'library', 'ink'];
const THEME_BG = { pop: '#fff6e3', terminal: '#050805', garden: '#f3f5ee', midnight: '#0e1424', library: '#f6efe2', ink: '#ffffff' };
const SHOTS = [
  {
    name: '01-timeline', headline: 'Write it down.<br>It comes <mark>back</mark><loop></loop>',
    support: 'A commonplace book that brings every quote and idea back in 7 days.',
    cards: [{ raw: '01-timeline', top: 330, bottom: 2560, pad: 40, x: 105, y: 740, s: 0.8 }],
  },
  {
    name: '02-linked', headline: 'Map how your<br>ideas <mark>connect</mark>.',
    support: 'Link any thought to another, then tap through to follow the thread.',
    cards: [{ raw: '10-linked', top: 330, bottom: 2600, pad: 80, x: 131, y: 750, s: 0.76 }],
  },
  {
    name: '03-blocks', headline: 'Photos, files<br>and <mark>more</mark>.',
    support: 'Write in Markdown, then add photo galleries and files to any thought.',
    cards: [{ raw: '06-markdown-photos', top: 330, bottom: 2600, pad: 80, x: 140, y: 790, s: 0.74, rot: -3 }],
  },
  {
    name: '04-blurred', headline: 'Hide the answer.<br><mark>Test</mark> yourself.',
    support: 'Blur part of any thought until you tap to reveal it.',
    cards: [
      { raw: '02-blurred-before', top: 330, bottom: 1520, x: 50, y: 760, s: 0.7, rot: -3 },
      { raw: '02-blurred-after', top: 330, bottom: 1520, x: 292, y: 1640, s: 0.7, rot: 3 },
    ],
  },
  {
    name: '05-learn', headline: 'Learn it<br>for <mark>good</mark>.',
    support: 'Tap Again or Got it. Each Got it waits longer: 7, 12, 20 days.',
    cards: [{ raw: '03-learn', top: 330, bottom: 2600, pad: 80, x: 131, y: 770, s: 0.76, rot: 3 }],
  },
  {
    name: '06-themes', headline: 'Six looks,<br><mark>all</mark> included.',
    support: 'Ink, Library, Midnight, Garden, Terminal and Pop.',
    cards: CASCADE.map((t, i) => ({
      raw: `04-themes-${t}`, top: 330, bottom: 1300, x: i % 2 ? 467 : 60, y: 700 + i * 280, s: 0.56, rot: i % 2 ? 3 : -3, bg: THEME_BG[t],
    })),
  },
  {
    name: '07-interval', headline: 'Pick when you<br>see it <mark>again</mark>.',
    support: 'Bring it back in 1, 3, 7 or 30 days, or set your own.',
    cards: [
      { raw: '05-interval', top: 330, bottom: 2340, x: 70, y: 740, s: 0.7 },
      { raw: '05-interval', top: 2360, bottom: 2620, x: 66, y: 2080, s: 0.9, rot: -3 },
    ],
  },
  {
    name: '08-search', headline: 'Find any thought<br>in a <mark>second</mark>.',
    support: 'Search every note and journal entry, active or archived.',
    cards: [{ raw: '07-search', top: 170, bottom: 2868, x: 62, y: 740, s: 0.88, rot: -2 }],
  },
  {
    name: '09-tags', headline: 'Sort with <mark>#tags</mark>.',
    support: 'Tag thoughts as you write, and give each tag its own color.',
    cards: [{ raw: '08-tags', top: 330, bottom: 2400, pad: 60, x: 131, y: 760, s: 0.76, rot: -3 }],
  },
  {
    name: '10-reminders', headline: 'Get a <mark>nudge</mark>,<br>not a nag.',
    support: 'One reminder a day at the time you pick, only when thoughts are due.',
    cards: [{ raw: '09-reminders', top: 150, bottom: 2700, x: 181, y: 760, s: 0.7, rot: 3, bg: '#1d1e22' }],
  },
];
