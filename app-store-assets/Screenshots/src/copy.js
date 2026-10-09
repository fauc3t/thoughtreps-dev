// All screenshot copy. `name` is the raw capture's file name in raw/ (set by ThoughtRepsUITests/ScreenshotTests.swift).
// `<mark>` highlights a word; `<loop></loop>` draws the loop mark. Lines of a headline are separated by <br>.
// Claims are checked against the shipped app: default interval 7 days (Settings), quick intervals 1d/3d/7d/30d plus
// "…" with more and "Custom…" (ThoughtDetailView), Markdown + gallery blocks, search scopes Active/Archived/All,
// tag colors (Change Color), one reminder a day at the chosen time (SettingsView, ReminderPlanner).
const SHOTS = [
  { name: '01-timeline', headline: 'Write it down.<br>It comes <mark>back</mark><loop></loop>', support: 'Write a thought and it returns to your timeline in 7 days.' },
  { name: '02-interval', headline: 'Pick when you<br>see it <mark>again</mark>.', support: 'Bring it back in 1, 3, 7 or 30 days, or set your own.' },
  { name: '03-markdown-photos', headline: 'Write in <mark>Markdown</mark>,<br>add photos.', support: 'Headings, lists, quotes and photo galleries in any thought.' },
  { name: '04-search', headline: 'Find any thought<br>in a <mark>second</mark>.', support: 'Search everything you have written, active or archived.' },
  { name: '05-tags', headline: 'Sort with <mark>#tags</mark>.', support: 'Tag thoughts as you write, and give each tag its own color.' },
  { name: '06-reminders', headline: 'Get a <mark>nudge</mark>,<br>not a nag.', support: 'One reminder a day at the time you pick, only when thoughts are due.' },
];
