// All screenshot copy, in App Store order. `name` is the output; `raws` are the captures it shows from raw/ (set by
// ThoughtRepsUITests/ScreenshotTests.swift), one phone each, laid out by `layout` (default: one phone; 'pair': before
// and after; 'grid': 3x2 with `labels` under the phones). `<mark>` highlights a word; `<loop></loop>` draws the loop
// mark. Lines of a headline are separated by <br>. Loaded by shot.html, preview.html and gen.mjs.
// Claims are checked against the shipped app: default interval 7 days (Settings), quick intervals 1d/3d/7d/30d plus
// "…" with more and "Custom…" (ThoughtDetailView), Markdown + gallery blocks, blurred blocks hidden until tapped
// ("Blur until tapped"), six free themes (AppTheme), search scopes Active/Archived/All, tag colors (Change Color),
// one reminder a day at the chosen time (SettingsView, ReminderPlanner).
// The first three show in search results. One supporting line per shot may carry a search word (commonplace book,
// quote, idea, note, journal) where it reads naturally.
const THEMES = ['Ink', 'Library', 'Midnight', 'Garden', 'Terminal', 'Pop'];
const SHOTS = [
  { name: '01-timeline', headline: 'Write it down.<br>It comes <mark>back</mark><loop></loop>', support: 'A commonplace book that brings every quote and idea back in 7 days.' },
  { name: '02-blurred', headline: 'Hide the answer.<br><mark>Test</mark> yourself.', support: 'Blur part of any thought until you tap to reveal it.', layout: 'pair', raws: ['02-blurred-before', '02-blurred-after'] },
  { name: '03-themes', headline: 'Six looks,<br><mark>all</mark> included.', support: 'Ink, Library, Midnight, Garden, Terminal and Pop.', layout: 'grid', raws: THEMES.map((t) => `03-themes-${t.toLowerCase()}`), labels: THEMES },
  { name: '04-interval', headline: 'Pick when you<br>see it <mark>again</mark>.', support: 'Bring it back in 1, 3, 7 or 30 days, or set your own.' },
  { name: '05-markdown-photos', headline: 'Write in <mark>Markdown</mark>,<br>add photos.', support: 'Headings, lists, quotes and photo galleries in any thought.' },
  { name: '06-search', headline: 'Find any thought<br>in a <mark>second</mark>.', support: 'Search every note and journal entry, active or archived.' },
  { name: '07-tags', headline: 'Sort with <mark>#tags</mark>.', support: 'Tag thoughts as you write, and give each tag its own color.' },
  { name: '08-reminders', headline: 'Get a <mark>nudge</mark>,<br>not a nag.', support: 'One reminder a day at the time you pick, only when thoughts are due.' },
];
