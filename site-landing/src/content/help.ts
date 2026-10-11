// Source of truth for the /help center. Every page, the hub, breadcrumbs,
// FAQ structured data, the sitemap and the prerender route list are generated
// from HELP_CATEGORIES and HELP_ARTICLES, so adding an article is one edit here.
//
// Copy is written against the Thought Reps 1.0 app: interface labels are quoted
// exactly as they appear in the app.

export type HelpCategorySlug =
  'getting-started' | 'writing' | 'reviewing' | 'your-data';

export interface HelpCategory {
  slug: HelpCategorySlug;
  title: string;
  description: string;
}

/**
 * Inline icons, usable in prose as `{icon:name}`. The value is the icon's
 * spoken name: the aria-label on the page and the words in plain-text output.
 */
export const HELP_ICONS = {
  plus: 'New thought',
  search: 'Search',
  settings: 'Settings',
  pin: 'Pin',
  unpin: 'Unpin',
  archive: 'Archive',
  snooze: 'Snooze',
  share: 'Share',
  import: 'Import',
  hash: 'Tags',
  tag: 'Tag',
  trash: 'Delete',
  undo: 'Restore',
  photo: 'Add image',
  block: 'Add block',
  bold: 'Bold',
  italic: 'Italic',
  list: 'List',
  checklist: 'Task',
  link: 'Link',
  code: 'Code',
  heading: 'Heading',
  more: 'More',
  clear: 'Remove',
  close: 'Close',
  calendar: 'Calendar',
  copy: 'Copy',
  check: 'Selected',
  palette: 'Change Color',
  stats: 'Stats',
} as const;

export type HelpIconName = keyof typeof HELP_ICONS;

export function isHelpIconName(name: string): name is HelpIconName {
  return Object.hasOwn(HELP_ICONS, name);
}

/** Static mockups drawn by HelpExamples.tsx. */
export const HELP_EXAMPLE_KINDS = [
  'loop',
  'editor',
  'thought-states',
  'timeline',
  'thought-card',
  'search-results',
  'format-bar',
  'markdown-pair',
  'gallery',
  'blurred-block',
  'tag-list',
  'color-sheet',
  'share-sheet',
  'snooze-menu',
  'interval-menu',
  'learn-bar',
  'swipe-actions',
  'pinned-archived',
  'notification',
  'settings-backup',
  'export-link',
  'import-link',
  'import-menu',
  'stats',
  'themes',
  'ipad-layout',
] as const;

export type HelpExampleKind = (typeof HELP_EXAMPLE_KINDS)[number];

export interface HelpExample {
  kind: HelpExampleKind;
  /** Visible under the mockup, and what screen readers get instead of it. */
  caption: string;
}

export interface HelpSection {
  heading?: string;
  paragraphs?: string[];
  steps?: string[];
  list?: string[];
  /** Drawn after the text. A section may hold only an example. */
  example?: HelpExample;
}

export interface HelpArticle {
  slug: string;
  category: HelpCategorySlug;
  /** Page heading and the start of the <title>; keep it short enough for the suffix. */
  title: string;
  /** Meta description and the lede under the heading. Plain text only. */
  description: string;
  /** Slugs of 2 to 4 related articles. */
  related: string[];
  /**
   * When true, each section is a question (`heading`) and its answer
   * (`paragraphs`), and the page also gets FAQPage structured data.
   */
  faq?: boolean;
  /**
   * Text may use `code`, [link text](/help/slug) and {icon:name}. Nothing else
   * is parsed. Write "tap {icon:search}": plain-text output reads "tap Search".
   * When a quoted label follows the icon, use `{icon:name|decorative}` so the
   * chip is hidden from screen readers and plain text.
   */
  sections: HelpSection[];
}

export const HELP_CATEGORIES: HelpCategory[] = [
  {
    slug: 'getting-started',
    title: 'Getting started',
    description:
      'What Thought Reps is, how to write a thought, and how it comes back.',
  },
  {
    slug: 'writing',
    title: 'Writing',
    description:
      'Markdown, images, text blocks you can blur, tags and saving from other apps.',
  },
  {
    slug: 'reviewing',
    title: 'Reviewing',
    description:
      'Snooze, intervals, Learn mode, pinning, archiving and the daily reminder.',
  },
  {
    slug: 'your-data',
    title: 'Your data',
    description:
      'Privacy, backups, moving to a new phone, feedback and common questions.',
  },
];

export const HELP_ARTICLES: HelpArticle[] = [
  {
    slug: 'what-is-thought-reps',
    category: 'getting-started',
    title: 'What Thought Reps is',
    description:
      'Thought Reps is a notebook for iPhone and iPad that brings your ideas back. Write a thought, and it returns to your timeline after a week.',
    related: ['write-your-first-thought', 'how-resurfacing-works', 'ipad', 'privacy'],
    sections: [
      {
        paragraphs: [
          'Thought Reps is a notebook for iPhone and iPad. You write something down. Later, it comes back to you, so you see it again. Most notes just sit in a long list and get forgotten.',
          'It works well for things you want to remember but tend to forget. A quote you liked. An article you meant to read. A word of the day you want to learn. A question to think about.',
        ],
      },
      {
        heading: 'The basic loop',
        steps: [
          'Write a thought. It takes a few seconds. You can use Markdown, images and #tags.',
          'Let it go. The thought leaves your timeline and waits 7 days, or whatever interval you pick.',
          'Meet it again. When the time is up, it shows on your timeline marked as due. Open it, and it heads out for another lap.',
        ],
        example: {
          kind: 'loop',
          caption:
            'Write a thought, let it wait, and meet it again when it is due.',
        },
      },
      {
        heading: 'What you get',
        list: [
          'Thoughts written in Markdown, with photos, image galleries and extra text blocks you can blur to quiz yourself.',
          'Tags, with a timeline for each tag.',
          'Pin, snooze and archive, so you choose what stays in front of you.',
          'An optional daily reminder.',
          'A calm Stats tab that shows how much you write and revisit.',
          'A share option, so you can save text and links from other apps.',
          'Backup files you own, and a one-time link for moving to a new device.',
        ],
      },
      {
        heading: 'Private by design',
        paragraphs: [
          'There is no account. Your thoughts are stored on your device, and the app works without internet. Read [Privacy: what stays on your phone](/help/privacy) to learn more.',
          'Thought Reps is made for iPhone and iPad. It needs iOS 18 or iPadOS 18 or later. See [Use Thought Reps on iPad](/help/ipad).',
        ],
      },
    ],
  },
  {
    slug: 'ipad',
    category: 'getting-started',
    title: 'Use Thought Reps on iPad',
    description:
      'Thought Reps runs on iPad with a three-column layout, keyboard shortcuts and drag and drop for images. Each device keeps its own thoughts.',
    related: ['the-timeline', 'images-and-galleries', 'backup-and-restore', 'move-to-a-new-phone'],
    sections: [
      {
        paragraphs: [
          'Thought Reps works on iPad as well as iPhone. It turns the wide screen into a three-column layout, adds keyboard shortcuts, and lets you drag images in.',
        ],
      },
      {
        heading: 'The layout',
        paragraphs: [
          'When the window is wide, you see three columns. The left one lists Timeline, Tags, Archive and Stats. The middle one shows the thoughts for what you picked. The right one shows the thought you opened. Tags and Search open in the middle column too.',
        ],
        example: {
          kind: 'ipad-layout',
          caption:
            'On a wide iPad window: the sidebar, the Timeline list, and an empty thought column.',
        },
      },
      {
        paragraphs: [
          'The right column says "Select a thought" until you pick one. The app never opens one for you, because opening a thought sends it back to wait for its next interval.',
          'Snooze, archive or delete the open thought, and the right column clears. Tap a tag inside a thought to see that tag\'s timeline in the middle column.',
          'When the window is narrow, like in Split View or Slide Over, you get the same tabs as on iPhone. It switches back as you resize. It works in Split View, Slide Over and Stage Manager, but you can only open one window. The iPad turns to any side. The iPhone stays upright.',
        ],
      },
      {
        heading: 'Keyboard shortcuts',
        paragraphs: [
          'These work with a hardware keyboard, on iPad and iPhone. Hold the ⌘ key to see them. They pause while a sheet or dialog is open.',
        ],
        list: [
          '⌘N: new thought. On a tag timeline, the new thought starts with that tag.',
          '⌘F: search your thoughts.',
          '⌘,: open Settings.',
          '⌘1, ⌘2, ⌘3, ⌘4: Timeline, Tags, Archive, Stats.',
          'In the editor, ⌘ and Return saves, and Esc cancels. If you changed something, it still asks before it throws the changes away.',
        ],
      },
      {
        heading: 'Drag in images',
        paragraphs: [
          'Drag a picture from Files, Photos or Safari into the editor. Drop it on the text to add it at the cursor. Drop it on a gallery to add it to that gallery. It is resized and stripped of location data, the same as a picture from your photo library.',
          'A web link that is not a picture is ignored. The app never downloads it. See [Add images and galleries](/help/images-and-galleries).',
        ],
      },
      {
        heading: 'Each device has its own thoughts',
        paragraphs: [
          'There is no sync. Your iPhone and your iPad each keep their own thoughts. To move them across, use [a backup file](/help/backup-and-restore) or [an export link](/help/move-to-a-new-phone).',
        ],
      },
    ],
  },
  {
    slug: 'write-your-first-thought',
    category: 'getting-started',
    title: 'Write your first thought',
    description:
      'Tap the + button, type your thought, and save it. Here is what happens next, and where to find your thought while it waits.',
    related: [
      'how-resurfacing-works',
      'search-your-thoughts',
      'markdown-formatting',
      'tags',
    ],
    sections: [
      {
        heading: 'Capture a thought',
        steps: [
          'Tap {icon:plus} at the bottom right. It is there on every tab. It hides while a thought is open.',
          'The "New thought" editor opens with the keyboard up. Type your thought.',
          'Tap "Save" at the top right. The button stays off until you type something.',
        ],
        example: {
          kind: 'editor',
          caption:
            'The editor, with a thought half written and the formatting bar above the keyboard. Only the line with the cursor shows its Markdown characters.',
        },
      },
      {
        paragraphs: [
          'To close the editor without saving, tap "Cancel". If you changed anything, it asks "Discard changes?" first, and swiping the editor down will not close it. That way you never lose a draft by accident.',
        ],
      },
      {
        heading: 'What the first line does',
        paragraphs: [
          'The first line of your thought becomes its title on the timeline. The next lines show underneath as a short preview. Heading marks like `#` are taken out of the title.',
        ],
      },
      {
        heading: 'Optional extras',
        list: [
          'Add `#tags` anywhere in the text to file the thought. See [Organize with tags](/help/tags).',
          'Add photos with the {icon:photo} button above the keyboard. See [Add images and galleries](/help/images-and-galleries).',
          'Add a text block and blur it to hide an answer. See [Quiz yourself with blurred blocks](/help/blurred-blocks).',
          'Under "Schedule", use "Comes back every" if this thought should return sooner or later than usual.',
        ],
      },
      {
        heading: 'Where does it go?',
        paragraphs: [
          'A saved thought waits before it first shows on the timeline, so it will not be there right away. That is on purpose. To find it sooner, tap {icon:search} on the Timeline and type a word from it. See [Search your thoughts](/help/search-your-thoughts). [Understanding the timeline](/help/the-timeline) tells you more.',
          'To change a thought later, open it and tap "Edit". Editing the text does not change when the thought comes back.',
        ],
      },
    ],
  },
  {
    slug: 'how-resurfacing-works',
    category: 'getting-started',
    title: 'How resurfacing works',
    description:
      'A thought waits, comes due, and returns to your timeline. See how the interval works and what opening, snoozing and archiving do.',
    related: [
      'the-timeline',
      'snooze-and-intervals',
      'learn-mode',
      'pin-and-archive',
    ],
    sections: [
      {
        paragraphs: [
          'Every thought is in one of four states. Only two things move it from one to another: time passing, and what you do with it.',
        ],
        example: {
          kind: 'thought-states',
          caption: 'The four states: waiting, due, pinned and archived.',
        },
      },
      {
        heading: 'The four states',
        list: [
          'Waiting. A new thought waits for its interval, counted from when you save it. By default that is 7 days. A waiting thought is not on your timeline.',
          'Due. When the wait is over, the thought shows on your timeline. The one that has been due longest is listed first.',
          'Pinned. A pinned thought stays at the top of your timeline all the time, due or not.',
          'Archived. An archived thought never comes back on its own. It stays in the Archive tab until you restore it.',
        ],
      },
      {
        heading: 'What opening a thought does',
        paragraphs: [
          'Opening a thought counts as seeing it. It goes back to waiting. Its next due date is its interval, counted from that moment. The card leaves your timeline when you go back to it, not while you read. So it will not vanish in the middle of a read.',
          'This is true wherever you open the thought from, even a tag page. Opening an archived thought does not requeue it.',
          'Thoughts in Learn mode are the exception. Opening one does not requeue it. You tell it how it went with "Again" or "Got it". See [Learn mode](/help/learn-mode).',
        ],
      },
      {
        heading: 'The interval',
        paragraphs: [
          'The default interval is 7 days. You can change the default in Settings. You can also give any one thought its own interval. See [Snooze a thought or change its interval](/help/snooze-and-intervals).',
        ],
      },
      {
        heading: 'If you miss a day',
        paragraphs: [
          'Nothing is lost. A due thought stays on your timeline until you open it, snooze it or archive it. Its card tells you how long it has waited, like "due 2d ago".',
        ],
      },
      {
        heading: 'Things that do not reset the timer',
        list: [
          'Editing the text of a thought.',
          'Snoozing. It pushes the due date forward, but it does not count as a view.',
        ],
      },
    ],
  },
  {
    slug: 'the-timeline',
    category: 'getting-started',
    title: 'Understanding the timeline',
    description:
      'The Timeline tab shows pinned thoughts and thoughts that are due. See what each card shows and how to find every thought, even waiting ones.',
    related: [
      'search-your-thoughts',
      'how-resurfacing-works',
      'pin-and-archive',
      'tags',
    ],
    sections: [
      {
        paragraphs: [
          'The app has four tabs: Timeline, Tags, Archive and Stats. The Timeline comes first. It only shows what needs your attention today. The Stats tab is a summary of your notebook. See [Stats](/help/stats).',
        ],
        example: {
          kind: 'timeline',
          caption:
            'The Timeline, with a pinned thought, a due thought, the search and settings buttons, and the round new thought button.',
        },
      },
      {
        heading: 'What is on the Timeline',
        list: [
          'A "Pinned" section at the top, with every pinned thought.',
          'A "Due" section below it, with thoughts whose wait is over, oldest first.',
        ],
      },
      {
        paragraphs: [
          'Thoughts that are still waiting are not shown here. When nothing is due, the Timeline says "All caught up". It also tells you what is coming next, like "3 thoughts come back tomorrow."',
        ],
      },
      {
        heading: 'Reading a card',
        list: [
          'The title is the first line of the thought. The preview is the lines after it.',
          'Tag chips show which tags the thought has.',
          'A small picture shows on the right if the thought has an image.',
          'A label like "due today" or "due 2d ago" shows how long it has been due. Pinned thoughts show {icon:pin} instead.',
        ],
        example: {
          kind: 'thought-card',
          caption:
            'A due card with a tag chip, a picture and "due 2d ago", and a pinned card with a pin.',
        },
      },
      {
        heading: 'Quick actions',
        list: [
          'Swipe right on a card to pin it. If it is already pinned, the same swipe unpins it.',
          'Swipe left to see two buttons. "Tomorrow" snoozes the thought for a day, and "Archive" archives it. On a pinned card, "Unpin" takes the place of "Tomorrow".',
          'Pull down to refresh the list.',
          'At the top right, tap {icon:search} to search, or {icon:settings} next to it to open Settings.',
        ],
      },
      {
        heading: 'Seeing every thought',
        paragraphs: [
          'The Timeline is not a list of everything you wrote. To find one thought, tap {icon:search} and search. See [Search your thoughts](/help/search-your-thoughts).',
          'To browse instead, open the {icon:hash} tab at the bottom and pick a tag. Or pick "Untagged" for thoughts with no tag. Each of those pages has a "Due" and "All" switch at the top right. "All" shows every thought that is not archived, due or not.',
        ],
      },
    ],
  },
  {
    slug: 'search-your-thoughts',
    category: 'getting-started',
    title: 'Search your thoughts',
    description:
      'Find any thought, whether it is due, waiting, pinned or archived. Search looks at your text, extra text blocks, gallery titles and tags.',
    related: [
      'the-timeline',
      'tags',
      'pin-and-archive',
      'how-resurfacing-works',
    ],
    sections: [
      {
        paragraphs: [
          'Search finds a thought by its words. That includes thoughts that are still waiting and not on your Timeline yet.',
        ],
      },
      {
        heading: 'Open search',
        steps: [
          'On the Timeline, tap {icon:search} at the top right, next to {icon:settings}.',
          'The "Search" screen opens with the "Search thoughts" box ready for typing.',
          'Type at least 2 characters. Results show up as you type.',
        ],
        example: {
          kind: 'search-results',
          caption:
            'Typing "reflec" finds "reflection". Matching words are bold, and each result shows where the thought stands.',
        },
      },
      {
        heading: 'What is searched',
        list: [
          'The text of your thoughts, without the Markdown symbols.',
          'The text of extra text blocks, blurred ones too, so a hidden answer can be found.',
          'The titles of image galleries.',
          'Tag names.',
        ],
      },
      {
        heading: 'How matching works',
        list: [
          'Capital letters and accents do not matter.',
          'Each word you type matches the start of a word. So "reflec" finds "reflection".',
          'Every word you type has to match, in any order. Only the first 8 words are used.',
          'The best matches come first, with the matching words in bold.',
        ],
      },
      {
        heading: 'Choose what to search',
        paragraphs: [
          'The switch at the top of the Search screen has three options. "Active" covers every thought that is not archived, whether it is due, waiting or pinned. "Archived" covers only archived thoughts. "All" covers everything.',
        ],
      },
      {
        heading: 'Reading a result',
        paragraphs: [
          'Each result shows the title, a snippet around the match, and the tag chips. It also shows where the thought stands: "Due", "Back later today", "Back in 3 days" or "Archived". Pinned thoughts show {icon:pin} instead.',
        ],
      },
      {
        heading: 'Opening a result',
        paragraphs: [
          'Tap a result to open the thought. Opening one that is not archived counts as seeing it, like anywhere else. It goes back to waiting for its next interval, unless it is in Learn mode. Opening an archived thought does not requeue it. See [How resurfacing works](/help/how-resurfacing-works).',
        ],
      },
      {
        heading: 'Search in the Archive',
        paragraphs: [
          'The Archive tab has its own "Search archive" box for archived thoughts. In its results, you can still swipe right to restore a thought or swipe left and tap "Delete".',
        ],
      },
      {
        heading: 'Good to know',
        list: [
          'Search runs on your phone and works offline.',
          'You may see "Indexing… results may be incomplete." That means Thought Reps is still updating its search list. It can happen right after the app starts. Results fill in when it is done.',
          'The app rebuilds the search list by itself. It is not part of your backup file.',
        ],
      },
    ],
  },
  {
    slug: 'themes',
    category: 'getting-started',
    title: 'Change the look with themes',
    description:
      'Pick one of six free themes to change the colors, title fonts and cards in Thought Reps. Your choice stays on your phone.',
    related: ['the-timeline', 'tags', 'faq'],
    sections: [
      {
        paragraphs: [
          'A theme changes how the app looks: colors, title fonts and the shape of your cards. All six themes are free.',
        ],
        steps: [
          'Tap {icon:settings} on the Timeline to open Settings.',
          'Under "Appearance", tap "Theme". It shows the one you use now.',
          'Tap a theme. It applies right away, and "In use" moves to it.',
        ],
        example: {
          kind: 'themes',
          caption:
            'The Themes screen. Each card previews its theme, and the one in use is marked.',
        },
      },
      {
        heading: 'The six themes',
        list: [
          '"Ink" is the default. Clean outlines, Archivo and Paper Mono.',
          '"Library" has warm paper, old-style serifs and oxblood ink.',
          '"Midnight" is deep navy and gold.',
          '"Garden" has soft sage, rounded type and pillowy cards.',
          '"Terminal" is green on black, with Menlo everywhere.',
          '"Pop" is cream and coral, with thick ink outlines.',
        ],
      },
      {
        heading: 'Light and dark',
        paragraphs: [
          '"Midnight" and "Terminal" are always dark, whatever your device is set to. The other four follow your device, so they switch between light and dark with it.',
        ],
      },
      {
        heading: 'What a theme does not change',
        paragraphs: [
          'Your thought text font is its own setting. Under "Appearance", "Thought text" stays "Paper Mono" or "System" whichever theme you pick. Settings and the editor keep the standard iOS look.',
          'Your theme is saved on your phone only. It is not part of a backup, so choose it again on a new phone.',
        ],
      },
    ],
  },
  {
    slug: 'markdown-formatting',
    category: 'writing',
    title: 'Format your thoughts with Markdown',
    description:
      'Use the formatting bar above the keyboard, or type Markdown yourself. See what each button adds and what Thought Reps can show.',
    related: ['images-and-galleries', 'tags', 'blurred-blocks'],
    sections: [
      {
        paragraphs: [
          'Markdown lets you format text by typing a few plain characters. You type it in the editor, and it looks formatted as you go. You do not have to learn it, because the editor has buttons for the common things.',
        ],
        example: {
          kind: 'markdown-pair',
          caption:
            'What you type on the left, and what you see when you open the thought on the right.',
        },
      },
      {
        heading: 'The formatting bar',
        paragraphs: [
          'While you type, a row of buttons sits above the keyboard. Select some text, and a button wraps it. Select nothing, and it adds an empty pair with the cursor in the middle. Tap the same button again to remove the formatting.',
        ],
        list: [
          'The {icon:heading} button adds `# ` at the start of the line.',
          'The {icon:bold} button wraps text in `**double asterisks**`.',
          'The {icon:italic} button wraps text in `_underscores_`.',
          'The {icon:list} button adds `- ` at the start of the line.',
          'The {icon:checklist} button adds `- [ ] `, which shows as a checklist item.',
          'The {icon:code} button wraps text in backticks.',
          'The {icon:tag} button types a `#` and shows your tags to pick from.',
          'The {icon:photo} button adds an image. See [Add images and galleries](/help/images-and-galleries).',
          'The {icon:block} button adds a block under your thought. See [Quiz yourself with blurred blocks](/help/blurred-blocks).',
        ],
        example: {
          kind: 'format-bar',
          caption:
            'The formatting bar. With "petrichor" selected, Bold wraps it in double asterisks.',
        },
      },
      {
        heading: 'Syntax steps aside',
        paragraphs: [
          'Headings are big, bold is bold, and links show only their text. The characters that make this happen are hidden, except on the line your cursor is on. There they come back, faded, so you can edit them. Code blocks fold into a thin bar until your cursor is inside.',
        ],
      },
      {
        heading: 'Lists keep going',
        paragraphs: [
          "Press return at the end of a bullet, numbered or task item, and the next item starts for you. Press return on an empty item to end the list. Delete at the start of an item to remove its bullet. Tap a task's box to tick or untick it.",
        ],
      },
      {
        heading: 'What you can write',
        list: [
          'Headings, bold and italic.',
          'Strikethrough, with `~~two tildes~~` on each side.',
          'Bullet lists, numbered lists and task lists.',
          'Quotes, started with `> `.',
          'Inline code, and code blocks fenced with three backticks.',
          'Links. Tap one in a thought to open it.',
          'Tables.',
          'Images you add from your own photos.',
        ],
      },
      {
        heading: 'Good to know',
        list: [
          'What you see in the editor is the same text you see when you open the thought. Only the look differs a little.',
          'You can select and copy text in a thought.',
          'Text blocks you add under a thought are styled as you type too, and the formatting bar works in them.',
        ],
      },
    ],
  },
  {
    slug: 'images-and-galleries',
    category: 'writing',
    title: 'Add images and galleries',
    description:
      'Put photos in the middle of a thought, or collect several in a gallery. Learn how to add, view and remove them, and what happens to the file.',
    related: ['markdown-formatting', 'blurred-blocks', 'backup-and-restore', 'ipad'],
    sections: [
      {
        paragraphs: [
          'You can add pictures two ways: inside the text, or as a gallery under it.',
        ],
      },
      {
        heading: 'Images inside the text',
        steps: [
          'In the editor, tap {icon:photo} in the row above the keyboard.',
          'Choose "Photo Library" or "Take Photo". "Paste Image" shows up when you have copied a picture.',
          'The picture is added where your cursor is, as a line of text like `![](img:…)`. It shows as a small picture in the text, and a thumbnail also shows under the text box.',
        ],
      },
      {
        paragraphs: [
          'That line is the image. Cut and paste it to move the picture. Delete it to remove the picture. You can also tap {icon:clear} on its thumbnail under the text box. Text blocks you add under a thought take images the same way.',
        ],
      },
      {
        heading: 'Galleries',
        paragraphs: [
          'A gallery is a row of pictures that scrolls sideways under your thought.',
        ],
        steps: [
          'In the editor, tap {icon:block} in the row above the keyboard. Or scroll to the "Blocks" section and tap "Add block".',
          'Choose "Image gallery". The editor scrolls to the new block.',
          'Type a title if you like. Then tap the {icon:plus} tile to add one or more images.',
        ],
        example: {
          kind: 'gallery',
          caption:
            'A gallery with a title and a row of pictures that scrolls sideways.',
        },
      },
      {
        paragraphs: [
          'A gallery needs at least one image. If you leave one empty, it is not saved.',
        ],
      },
      {
        heading: 'Viewing images',
        paragraphs: [
          "Tap any image in a thought to open it full screen. Swipe sideways to move between the thought's images. Pinch or double-tap to zoom. Tap {icon:close} at the top right to close.",
        ],
      },
      {
        heading: 'What happens to your pictures',
        list: [
          'Big photos are resized so the longest side is at most 2048 pixels. This keeps the app light.',
          'All metadata is removed from the copy Thought Reps keeps. That includes where and when the photo was taken.',
          'Images stay on your device and are in your backup files.',
          'Only photos you add are shown. A picture linked from a website will not load.',
        ],
      },
      {
        heading: 'Camera access',
        paragraphs: [
          'The first time you choose "Take Photo", iOS asks if Thought Reps may use the camera. It only uses it to take photos for your thoughts.',
        ],
      },
    ],
  },
  {
    slug: 'blurred-blocks',
    category: 'writing',
    title: 'Quiz yourself with blurred blocks',
    description:
      'Add a text block under your thought and blur it. It stays hidden until you tap it, so you can test yourself each time the thought returns.',
    related: [
      'write-your-first-thought',
      'markdown-formatting',
      'how-resurfacing-works',
      'learn-mode',
    ],
    sections: [
      {
        paragraphs: [
          'A thought can hold more than one piece of text. The text you type first is the main text. You can add text blocks under it. Turn on "Blur until tapped" for a block, and it stays hidden behind a heavy blur until you tap it.',
          'That turns a thought into a small quiz. Write the question in the main text. Put the answer in a blurred block. Try to remember it before you reveal it. It is a good fit for words of the day, definitions, names and quotes you want to finish.',
        ],
        example: {
          kind: 'blurred-block',
          caption:
            'Try it. Tap the block, or tab to it and press space, to reveal the answer.',
        },
      },
      {
        heading: 'Add a text block',
        steps: [
          'In the editor, tap {icon:block} in the row above the keyboard. Or scroll to the "Blocks" section and tap "Add block".',
          'Choose "Text". The editor scrolls to the new block and puts the cursor in its "Markdown text" box.',
          'Type the text. Markdown, #tags and images work here just like in the main text.',
          'Type a label if you like, such as "Answer".',
          'Turn on "Blur until tapped" to hide it.',
        ],
      },
      {
        paragraphs: [
          'You can add as many blocks as you like. A text block with no text is dropped when you save. To remove a block, swipe it left in the editor. The main text always stays first, and you cannot remove or blur it.',
        ],
      },
      {
        heading: 'Using it',
        paragraphs: [
          'Blocks show under the main text. A blurred block shows its label and "Tap to reveal". If you gave it no label, it is called "Hidden". Tap it to see the text. Tap again to hide it ("Hide").',
          'A blurred block is hidden again each time you open the thought. So every visit is a fresh try at remembering. To be asked how it went each time, turn on [Learn mode](/help/learn-mode).',
        ],
      },
      {
        heading: 'Example',
        list: [
          'Main text: "Word of the day: petrichor. What does it mean?"',
          'Text block labelled "Answer", blurred: "The smell of rain on dry ground."',
        ],
      },
      {
        heading: 'Good to know',
        list: [
          'Tags in any text block file the thought, and search finds text in every block, blurred ones too.',
          'The title, the timeline preview and pinning come from the main text.',
          'Blocks, and whether each is blurred, are in your backups.',
          'Older blurred blocks, and older backups, open as blurred text blocks.',
        ],
      },
    ],
  },
  {
    slug: 'tags',
    category: 'writing',
    title: 'Organize with tags',
    description:
      'Type #tags anywhere in a thought to file it. Each tag gets its own timeline, and the Tags tab shows how many thoughts are due.',
    related: [
      'the-timeline',
      'search-your-thoughts',
      'write-your-first-thought',
      'change-tag-color',
    ],
    sections: [
      {
        heading: 'Make a tag',
        paragraphs: [
          'Type a `#` and a word anywhere in your thought, like `#quotes` or `#to-read`. That is all it takes. Tags are tinted as you type, and the editor lists the ones it found under the text box.',
          'A tag can have letters, numbers, underscores and hyphens. It needs at least one letter, so `#1` is not a tag.',
        ],
      },
      {
        heading: 'Rules worth knowing',
        list: [
          'Tags are not case sensitive. `#Quotes` and `#quotes` are the same tag. The first spelling you used is the one shown.',
          'Tags work in any text block you add under a thought, too. See [Quiz yourself with blurred blocks](/help/blurred-blocks).',
          'A heading like `# Title` is a heading, not a tag.',
          'A `#` inside a web address, inside code, or right after a letter (as in C#) is not a tag.',
          'Tags are read again every time you save. So if you delete `#quotes` from the text, the tag leaves that thought.',
        ],
      },
      {
        heading: 'Pick from your existing tags',
        paragraphs: [
          'When you type a `#`, the row above the keyboard shows your tags and how many thoughts use each. Tap one to finish it. The {icon:tag} button on the formatting bar types a `#` for you.',
        ],
      },
      {
        heading: 'The Tags tab',
        paragraphs: [
          'Open the {icon:hash} tab at the bottom to see every tag.',
        ],
        list: [
          'Every tag is listed with the number of thoughts it has, and a "due" count when some are due.',
          '"Untagged" collects thoughts that have no tag.',
          'Use the search box, "Filter tags", to find a tag by name.',
          'Tap a tag to open its page. It works like the Timeline, but only for that tag. It has a "Due" and "All" switch at the top.',
          "The dot next to each tag is its color. To change it, see [Change a tag's color](/help/change-tag-color).",
        ],
        example: {
          kind: 'tag-list',
          caption:
            'The Tags tab. Each tag shows its due count in bold and its total, and "Untagged" sits below.',
        },
      },
      {
        heading: 'Jumping to a tag',
        paragraphs: [
          "Tap a tag chip on a thought, or a tag in its text, to go straight to that tag's page.",
          "Tap {icon:plus} while you are on a tag's page, and the new thought starts with that tag already filled in.",
        ],
      },
      {
        paragraphs: [
          'Tag counts only include thoughts that are not archived. A tag leaves the list when no thought uses it any more.',
        ],
      },
    ],
  },
  {
    slug: 'change-tag-color',
    category: 'writing',
    title: "Change a tag's color",
    description:
      'Pick a color for any tag. It shows on the Tags tab, on tag chips and when you type a #tag.',
    related: ['tags', 'the-timeline', 'backup-and-restore'],
    sections: [
      {
        paragraphs: [
          'Every tag gets a color on its own, picked from its name. You can choose a different one.',
        ],
      },
      {
        heading: 'Change it',
        steps: [
          'Open the {icon:hash} tab and press and hold a tag.',
          'Tap "Change Color".',
          'Tap the color you want. It saves right away and the sheet closes.',
        ],
        paragraphs: [
          'Want a color that isn\'t in the list? Tap "Custom" and pick any color. It saves when you close the picker.',
          'You can also do it from a tag\'s page. Tap {icon:palette} next to the "Due" and "All" switch. "Untagged" has no color to change.',
        ],
        example: {
          kind: 'color-sheet',
          caption:
            'The "Color" sheet. "Automatic" is the tag\'s own pick, "Custom" opens a color picker, and the checkmark shows the current color. Tap "Cancel" to leave it as it is.',
        },
      },
      {
        heading: 'Where the color shows',
        list: [
          'The dot next to the tag on the Tags tab.',
          'Tag chips on your thoughts.',
          'The tag list above the keyboard when you type a `#`.',
        ],
      },
      {
        heading: 'Good to know',
        list: [
          'Pick "Automatic" to go back to the color the tag started with.',
          'Backups keep tag colors. When you import, a tag you already have keeps its own color.',
          'A tag leaves the list when no thought uses it, and its color goes too. If you add it back later, it starts on "Automatic".',
        ],
      },
    ],
  },
  {
    slug: 'save-from-other-apps',
    category: 'writing',
    title: 'Save from other apps',
    description:
      'Send text, a link or a Markdown file to Thought Reps from Safari, Notes or any app with a share button. It shows up the next time you open the app.',
    related: ['write-your-first-thought', 'the-timeline', 'tags'],
    sections: [
      {
        paragraphs: [
          'You can send things to Thought Reps without opening it. Use the share button in other apps.',
        ],
      },
      {
        heading: 'What you can share',
        list: [
          'Text you have selected, like a quote from an article.',
          'A web link, like the page you are reading in Safari.',
          'A single text or Markdown file, up to 1 MB.',
        ],
      },
      {
        paragraphs: [
          'Photos cannot be shared in. Neither can several files or links at once.',
        ],
      },
      {
        heading: 'How to share',
        steps: [
          'Tap {icon:share} in the other app.',
          'Choose Thought Reps. If you do not see it, scroll to the end of the row of apps, tap "More", and turn it on.',
          'A "New Thought" screen opens with what you shared already filled in. If you shared text and a link, the link goes on its own line under the text.',
          'Edit it if you like, and add any #tags. Then tap "Save", or "Cancel" to throw it away.',
        ],
        example: {
          kind: 'share-sheet',
          caption:
            'Thought Reps in the share sheet, and the "New Thought" screen with a quote and a link already filled in.',
        },
      },
      {
        heading: 'Where it goes',
        paragraphs: [
          'The thought is saved in a hand-off folder. It is added to Thought Reps the next time you open the app. After that, it acts like any other thought. It waits for the default interval before it shows on your timeline. To find it sooner, tap {icon:search} on the Timeline. See [Search your thoughts](/help/search-your-thoughts) and [Understanding the timeline](/help/the-timeline).',
        ],
      },
      {
        heading: 'If a file cannot be read',
        paragraphs: [
          'Thought Reps tells you if a shared file is bigger than 1 MB or is not UTF-8 text. Sharing text or a link always works.',
        ],
      },
      {
        heading: 'Privacy',
        paragraphs: [
          "Sharing does not use the internet. What you share goes straight to your phone's own storage for Thought Reps.",
        ],
      },
    ],
  },
  {
    slug: 'snooze-and-intervals',
    category: 'reviewing',
    title: 'Snooze a thought or change its interval',
    description:
      'Push a thought back by a day or a week, or choose how often it returns: one default for everything, or a custom interval for a single thought.',
    related: [
      'how-resurfacing-works',
      'learn-mode',
      'pin-and-archive',
      'the-timeline',
    ],
    sections: [
      {
        heading: 'Snooze',
        paragraphs: [
          "Snoozing pushes a thought's return date forward. It does not count as a view. Use it when you are not ready for a thought today.",
        ],
        list: [
          'On the Timeline, swipe left on a card and tap {icon:snooze|decorative} "Tomorrow".',
          'Inside a thought, tap {icon:more} at the top right. Then choose "Snooze until tomorrow" or "Snooze a week". The thought closes.',
        ],
        example: {
          kind: 'snooze-menu',
          caption:
            'The More menu inside a thought, with both snooze choices, "Archive" and "Delete".',
        },
      },
      {
        heading: 'The default interval',
        paragraphs: [
          'Tap {icon:settings} on the Timeline to open Settings. Under "Resurfacing", "Default interval" sets how long a thought waits. It starts at 7 days. You can set anything from 1 to 90 days.',
          'The default applies to thoughts with no interval of their own, and to future views. It does not move the due dates thoughts already have.',
        ],
      },
      {
        heading: 'An interval for one thought',
        paragraphs: [
          'Some thoughts need a different pace. A word you are memorizing might come back every day. A quote might come back every month.',
        ],
        list: [
          'In the editor, under "Schedule", use the "Comes back every" menu.',
          'On an open thought, use the bar at the bottom. Tap 1d, 3d, 7d or 30d. The one in use is filled in.',
        ],
      },
      {
        paragraphs: [
          'For more choices, tap "…" on that bar. The menu offers "Default", which shows your default in parentheses, like "Default (7 days)". Then come Day, 3 days, Week, 2 weeks, Month and 3 months. "Custom…" is for anything else. Custom opens a wheel. Pick a number and days, weeks or months, up to a year.',
        ],
        example: {
          kind: 'interval-menu',
          caption:
            'The bar at the bottom of an open thought with 7d chosen, and the menu that "…" opens.',
        },
      },
      {
        heading: 'What changing an interval does',
        paragraphs: [
          "When you change a thought's interval, the new interval is counted from the last time you opened it. If you never opened it, it is counted from when you wrote it. So a shorter interval can make a thought due right away.",
        ],
      },
    ],
  },
  {
    slug: 'learn-mode',
    category: 'reviewing',
    title: 'Learn mode: Again and Got it',
    description:
      'Turn on Learn mode for a thought you want to remember. Tell it how it went, and it comes back sooner or later, with longer waits as you get it right.',
    related: [
      'how-resurfacing-works',
      'snooze-and-intervals',
      'blurred-blocks',
      'pin-and-archive',
    ],
    sections: [
      {
        paragraphs: [
          'Most thoughts come back on a fixed interval, and opening one is enough. Learn mode is for thoughts you want to actually learn, like a word and its meaning. Pair it with a [blurred block](/help/blurred-blocks) to hide the answer. When the thought comes due, you try to recall it, then say how it went.',
          'Learn mode is off by default, and you turn it on one thought at a time. Thoughts that are not in Learn mode work as before.',
        ],
        example: {
          kind: 'learn-bar',
          caption:
            'The bar at the bottom of a due Learn thought. Each button shows when the thought will come back.',
        },
      },
      {
        heading: 'Turn it on',
        list: [
          'On an open thought, switch on "Learn" in the bar at the bottom.',
          'Or in the editor, under "Schedule", turn on "Learn mode".',
        ],
      },
      {
        paragraphs: [
          'The thought comes back tomorrow for its first review. To turn it off, flip the same switch. The thought goes back to its fixed interval, counted from the last time you opened it.',
        ],
      },
      {
        heading: 'Again and Got it',
        paragraphs: [
          'When a Learn thought is due, the bar at the bottom shows two buttons instead of the interval choices. Each one shows when the thought will return.',
        ],
        list: [
          '"Got it" means you remembered. The first time, the wait is the thought\'s interval, 7 days by default. After that, each "Got it" makes the wait about 1.7 times longer, up to 365 days. It goes 7, 12, 20, 34, 58, 99, 168, 286 and then 365 days.',
          '"Again" means you did not. The thought comes back tomorrow, and the waits start over from the interval.',
        ],
      },
      {
        heading: 'Good to know',
        list: [
          'Opening a Learn thought does not requeue it. Only the buttons do. If you close it without choosing, it stays due.',
          'When a Learn thought is waiting, the bar shows when it is back, like "Back tomorrow" or "Back Oct 23".',
          'A pinned Learn thought shows "Pinned · not reviewed" and has no buttons. Unpin it to review it.',
          'In the editor, the interval is called "First wait". Changing it does not move the due date.',
          'Learn thoughts have a small "LEARN" mark on their card on the Timeline.',
          'Your backups keep Learn mode and each thought\'s current wait.',
        ],
      },
    ],
  },
  {
    slug: 'pin-and-archive',
    category: 'reviewing',
    title: 'Pin and archive thoughts',
    description:
      'Pin thoughts you want in front of you all the time, and archive the ones you are done with. You can restore an archived thought whenever you like.',
    related: [
      'the-timeline',
      'how-resurfacing-works',
      'snooze-and-intervals',
      'daily-reminders',
    ],
    sections: [
      {
        heading: 'Pin a thought',
        paragraphs: [
          'A pinned thought stays in the "Pinned" section at the top of your Timeline all the time, due or not. It is good for things you want to see every day, like a set of weekly review questions.',
        ],
        list: [
          'Swipe right on a card on the Timeline.',
          'Or tap {icon:pin} at the top of an open thought.',
        ],
        example: {
          kind: 'swipe-actions',
          caption:
            'Swipe right on a card to pin it. Swipe left to see "Tomorrow" and "Archive".',
        },
      },
      {
        paragraphs: [
          'To unpin, do the same again. Or swipe left on the card and tap {icon:unpin|decorative} "Unpin". Pinned thoughts do not count in your daily reminder.',
        ],
      },
      {
        heading: 'Archive a thought',
        paragraphs: [
          'Archive a thought when you are done with it. It leaves the Timeline and your tag pages, and it never comes back on its own. Archiving also unpins it.',
        ],
        list: [
          'Swipe left on a card and tap {icon:archive|decorative} "Archive".',
          'Or open the thought, tap {icon:more} at the top right, and choose "Archive".',
        ],
      },
      {
        heading: 'The Archive tab',
        list: [
          'Open the {icon:archive} tab at the bottom to see archived thoughts. They are listed newest first, with the date they were archived.',
          'Use the "Search archive" box to find an old thought. See [Search your thoughts](/help/search-your-thoughts).',
          'Swipe right on one to restore it.',
          'Opening an archived thought does not requeue it.',
          'Archived thoughts show in the counts on the {icon:stats} tab. See [Stats](/help/stats).',
        ],
        example: {
          kind: 'pinned-archived',
          caption:
            'A pinned thought stays on the Timeline. An archived thought lives in the Archive tab.',
        },
      },
      {
        heading: 'Restore',
        paragraphs: [
          'A restored thought is due right away, so it shows on your Timeline at once. You can also restore from inside the thought. Tap {icon:more}, then {icon:undo|decorative} "Restore".',
        ],
      },
      {
        heading: 'Delete',
        paragraphs: [
          'Delete removes a thought for good, with its images and blocks. In the Archive, swipe left on a thought and tap {icon:trash|decorative} "Delete". Inside a thought, {icon:more} also has "Delete". Either way, it asks you to confirm. You cannot undo a delete. Archive instead if you might want it back.',
        ],
      },
    ],
  },
  {
    slug: 'stats',
    category: 'reviewing',
    title: 'Stats: how you use the app',
    description:
      'The Stats tab shows how many thoughts you wrote, how often you revisit them and how much you write each week. It is all worked out on your phone.',
    related: [
      'the-timeline',
      'how-resurfacing-works',
      'pin-and-archive',
      'privacy',
    ],
    sections: [
      {
        paragraphs: [
          'Open the {icon:stats} tab at the bottom to see a quiet summary of your notebook. There are no streaks, goals or badges. It is just a look at what you have done.',
          'Everything is worked out on your phone from your own thoughts. Nothing is sent anywhere. The numbers refresh each time you open the tab.',
        ],
        example: {
          kind: 'stats',
          caption:
            'The Stats tab, with the basics, the most revisited thought and the writing rhythm.',
        },
      },
      {
        heading: 'Basics',
        list: [
          '"Thoughts written" is every thought you have made, with how many are from this month.',
          '"Revisits" adds up how many times you have opened your thoughts. It also tells you how many thoughts you have seen at least once. Opening a thought from anywhere counts, since opening it sends it on another lap.',
          '"Active" is the thoughts that are not archived.',
          '"Archived" is the thoughts in your Archive.',
        ],
      },
      {
        heading: 'Most revisited',
        paragraphs: [
          'Once a thought has been opened 10 times or more, the thought you open most often shows up here as a card, like "Seen 14 times". Tap it to open the thought. Archived thoughts are left out.',
        ],
      },
      {
        heading: 'Writing rhythm',
        paragraphs: [
          'The grid has one square for each of the last 52 weeks, with the newest last. A darker square means you wrote more that week. An empty outline means you wrote nothing. Archived thoughts count too. Under the grid, you see the total for the last year, like "42 thoughts in the last year".',
        ],
      },
    ],
  },
  {
    slug: 'daily-reminders',
    category: 'reviewing',
    title: 'Set up a daily reminder',
    description:
      'Turn on one notification a day, at a time you pick, when thoughts are back. See how it counts, what it says and how to fix denied permissions.',
    related: ['how-resurfacing-works', 'pin-and-archive', 'privacy'],
    sections: [
      {
        heading: 'Turn it on',
        steps: [
          'Tap {icon:settings} on the Timeline to open Settings.',
          'Under "Reminder", turn on "Daily reminder".',
          'The first time, iOS asks if Thought Reps can send notifications. Choose Allow.',
          'Pick a time with the "Time" row. The default is 8:00 AM.',
          'You may not need to do this yourself. After you save your first thought, the app offers to turn reminders on, once. You can always change it here later.',
        ],
      },
      {
        heading: 'What the reminder says',
        paragraphs: [
          'The notification is from "Thought Reps". It reads like "3 thoughts are back today" or "1 thought is back today". Tap it to open your Timeline.',
        ],
        example: {
          kind: 'notification',
          caption: 'The daily reminder, as it shows on your Lock Screen.',
        },
      },
      {
        heading: 'When it is sent',
        list: [
          'You get at most one reminder a day, at the time you pick.',
          'If nothing is due, you get no reminder that day.',
          'The count includes thoughts due by that time, even ones that have waited a while.',
          'Pinned and archived thoughts are never counted.',
        ],
      },
      {
        heading: 'If you are away for a while',
        paragraphs: [
          'The app plans your reminders ahead of time. It updates the plan whenever you open or leave it. If you stay away, a few follow-up reminders come about 2 weeks, a month and 3 months later. They read like "3 thoughts are waiting for you". After that, the reminders stop until you open the app again.',
        ],
      },
      {
        heading: 'If it does not work',
        paragraphs: [
          'If you turned notifications off for Thought Reps in iOS, Settings shows "Notifications are off for Thought Reps in iOS Settings" and an "Open Settings" button. Turn notifications on there. Then switch "Daily reminder" on again.',
        ],
      },
      {
        heading: 'Local only',
        paragraphs: [
          'Reminders are made on your device. They are not sent from a server. The app never puts a number badge on its icon.',
        ],
      },
    ],
  },
  {
    slug: 'privacy',
    category: 'your-data',
    title: 'Privacy: what stays on your phone',
    description:
      'Thought Reps has no account and keeps your thoughts on your device. See when the app uses the internet, and what is and is not ever sent.',
    related: ['move-to-a-new-phone', 'send-feedback', 'backup-and-restore'],
    sections: [
      {
        heading: 'Your thoughts stay on your phone',
        paragraphs: [
          'There is no account and nothing to sign in to. Your thoughts, images, tags and settings are stored on your device. The app works without internet.',
        ],
      },
      {
        heading: 'When the app uses the internet',
        paragraphs: [
          'The app only uses the internet for two things, and you start both yourself:',
        ],
        list: [
          'Sending feedback.',
          'Creating, checking or revoking an export link.',
        ],
      },
      {
        paragraphs: [
          "The share option does not use the internet, and notifications are made on your phone. Requests to our service are signed with Apple's App Attest. That lets us accept them only from a real copy of the app.",
        ],
      },
      {
        heading: 'Feedback',
        paragraphs: [
          'A feedback message has what you wrote, your email so we can reply, and your app version, iOS version and device model. It never includes your thoughts. See [Send feedback](/help/send-feedback).',
        ],
      },
      {
        heading: 'Export links',
        paragraphs: [
          'If you share an export as a link, your backup file is encrypted on your device before it is uploaded. The lock is AES-256-GCM. The key is in the part of the link after the `#`. Web browsers never send that part to a server. So the file we hold is unreadable to us. The file is deleted after one download, or after 24 hours. You can revoke the link in Settings. See [Move to a new phone with an export link](/help/move-to-a-new-phone).',
        ],
      },
      {
        heading: 'Backups are yours',
        paragraphs: [
          'A backup file goes where you put it: Files, AirDrop, iCloud Drive or anywhere else you share it. Anyone who has the file can read it, so keep it somewhere you trust.',
          'Your thoughts live on your phone, so deleting the app deletes them. Make a backup first if you want to keep them. See [Back up and restore your thoughts](/help/backup-and-restore).',
        ],
      },
      {
        heading: 'Questions',
        paragraphs: [
          'Email hello@thoughtreps.com. You can read the full [privacy policy](/privacy) too.',
        ],
      },
    ],
  },
  {
    slug: 'backup-and-restore',
    category: 'your-data',
    title: 'Back up and restore your thoughts',
    description:
      'Export every thought, tag and image to a .thoughtreps file you keep, and import it later. Importing merges, keeping the newest change to each thought.',
    related: ['move-to-a-new-phone', 'ipad', 'privacy', 'faq'],
    sections: [
      {
        paragraphs: [
          'A backup is one file that ends in `.thoughtreps`. It holds all your thoughts, with their tags, tag colors, blocks and images. It also remembers if each one is pinned or archived. It does not hold your app settings, like the default interval and reminder time.',
        ],
      },
      {
        heading: 'Make a backup',
        steps: [
          'Tap {icon:settings} on the Timeline to open Settings.',
          'In the "Backup" section, tap {icon:share|decorative} "Export…". A progress bar shows while the file is built.',
          'The iOS share sheet opens. Save the file to Files or iCloud Drive, AirDrop it, or send it anywhere you like.',
        ],
        example: {
          kind: 'settings-backup',
          caption: 'The "Backup" section in Settings.',
        },
      },
      {
        paragraphs: [
          'The file is named like `ThoughtReps-export-2026-10-05.thoughtreps`, with the date you made it. A big library with lots of images can take a while to export, so give it a moment.',
        ],
      },
      {
        heading: 'Restore from a backup',
        steps: [
          'In Settings, under "Backup", tap {icon:import|decorative} "Import…". Then choose "From a File…" and pick your `.thoughtreps` file.',
          'Thought Reps checks the file and shows a summary, like "12 thoughts · 3 images — 5 new, 2 newer, 5 already up to date".',
          'Tap "Import". When it is done, you see how many thoughts came in.',
        ],
      },
      {
        paragraphs: [
          'You can also open a `.thoughtreps` file from Files or AirDrop and choose Thought Reps. That starts the same steps. If you have an export link instead of a file, choose "From a Link…". See [Move to a new phone with an export link](/help/move-to-a-new-phone).',
        ],
        example: {
          kind: 'import-menu',
          caption:
            'Tapping "Import…" offers "From a File…" and "From a Link…".',
        },
      },
      {
        heading: 'How importing merges',
        list: [
          'Thoughts that are new to this phone are added.',
          'If a thought is already on this phone, Thought Reps keeps the newest change to each part: the text, the schedule, and pinned or archived. It also keeps the higher view count.',
          'An import never deletes anything on your phone. Importing the same file twice changes nothing.',
          'Imported thoughts bring their schedule, pins and archive state.',
        ],
      },
      {
        heading: 'Good to know',
        list: [
          'Thought Reps can only import its own backup files, not files from other apps.',
          'Only one export or import can run at a time.',
          'If an import stops early, run it again. It picks up what is missing.',
        ],
      },
    ],
  },
  {
    slug: 'move-to-a-new-phone',
    category: 'your-data',
    title: 'Move to a new phone with an export link',
    description:
      'Share your backup as a one-time link that works for 24 hours. It is encrypted on your device first, so only the link can open it.',
    related: ['backup-and-restore', 'ipad', 'privacy', 'faq'],
    sections: [
      {
        paragraphs: [
          'An export link gets your thoughts onto another device when AirDrop or iCloud Drive is not handy. Maybe you are moving to a new phone. Maybe you want the file on a computer first. On an iPhone or iPad, Thought Reps can import the link directly, with no file to save. If you can AirDrop the file, [a regular backup](/help/backup-and-restore) is simpler.',
        ],
      },
      {
        heading: 'Create a link',
        steps: [
          'Open Settings, then go to the "Backup" section.',
          'Tap {icon:link|decorative} "Share export as link". Thought Reps builds your backup, encrypts it and uploads it.',
          'When it is ready, the link shows with its expiry time. Tap {icon:copy|decorative} "Copy link" or {icon:share|decorative} "Share link".',
        ],
        example: {
          kind: 'export-link',
          caption:
            'An open export link in Settings, with its expiry time and the "Copy link", "Share link" and "Revoke link" rows.',
        },
      },
      {
        heading: 'Import it in the app',
        steps: [
          'Install Thought Reps on the new phone and send yourself the link.',
          'In Thought Reps, open Settings, then under "Backup" tap {icon:import|decorative} "Import…" and choose "From a Link…". The "Import from Link" sheet opens.',
          'Paste the link into "Paste your export link". Or tap "Paste" to use what you copied. Then tap "Continue".',
          'Thought Reps shows the size and when the link expires. Tap "Import". "Downloading…" shows the progress.',
          'You then see the usual summary, like "12 thoughts · 3 images — 5 new, 2 newer, 5 already up to date". Tap "Import" on the summary to finish.',
        ],
        example: {
          kind: 'import-link',
          caption:
            'The "Import from Link" sheet: first the "Paste your export link" field with "Paste" and "Continue", then the size, expiry and "Import" button.',
        },
      },
      {
        paragraphs: [
          'On an iPhone or iPad with Thought Reps installed, you can also just tap the link. It opens the app straight to "Import from Link". You still tap "Import" yourself. Nothing is imported until you do.',
        ],
      },
      {
        heading: 'If the link does not work',
        list: [
          '"This link was already used." The link works once. Make a new one on the old phone.',
          '"This link has expired." Links last 24 hours. Make a new one.',
          '"This link was turned off." It was revoked or replaced. Use the newest link.',
          '"We couldn\'t find this link." Check that you copied all of it, including the part after the `#`.',
          '"This doesn\'t look like a Thought Reps export link." Paste the whole link, which starts with `https://transfer.thoughtreps.com/x/`.',
        ],
      },
      {
        heading: 'Use a computer or another browser',
        steps: [
          'Open the link in a browser. The page is called "Your Thought Reps export".',
          'Tap "Download". Your browser unlocks the file and saves it as a `.thoughtreps` file.',
          'Send the file to your phone with AirDrop or Files, open it with Thought Reps and import it. See [Back up and restore your thoughts](/help/backup-and-restore) for the steps.',
        ],
      },
      {
        heading: 'How the link behaves',
        list: [
          'It works once. The first download or import uses it up. Just opening the page does not.',
          'It expires after 24 hours if nobody uses it.',
          'You have one open link at a time. A new one replaces the old one, and you are asked to confirm.',
          'The exported file can be up to 100 MB. For something bigger, use "Export…" and send the file.',
          'There is a daily limit on how many links you can make.',
        ],
      },
      {
        heading: 'Revoke a link',
        paragraphs: [
          'The open link stays in Settings, with its expiry time, until it is used or it expires. Tap "Revoke link" to stop it right away.',
        ],
      },
      {
        heading: 'Keeping it private',
        paragraphs: [
          'Your file is encrypted on your device before it is uploaded. The key is only in the link after the `#`, and browsers do not send that part to us. We cannot read what you upload. That also means anyone with the whole link can download the file once, so only send it to yourself. A copied link also leaves your clipboard when it expires.',
        ],
      },
    ],
  },
  {
    slug: 'send-feedback',
    category: 'your-data',
    title: 'Send feedback',
    description:
      'Ask for a feature or report a problem from Settings. Your message goes straight to us with your email, and never includes your thoughts.',
    related: ['privacy', 'faq'],
    sections: [
      {
        heading: 'How to send it',
        steps: [
          'Tap {icon:settings} on the Timeline to open Settings.',
          'Under "Send Feedback", tap "Request a Feature" or "Report a Problem".',
          'Write your message. It can be up to 5,000 characters, and a counter shows how many you have used.',
          'Enter your email so we can reply. The app remembers it for next time.',
          'Tap "Send". You see "Thanks for your feedback" when it has gone through.',
        ],
      },
      {
        heading: 'What is included',
        paragraphs: [
          'The form lists what is sent with your message: your app version, iOS version and device model. Your thoughts are never attached.',
        ],
      },
      {
        heading: 'If it does not send',
        list: [
          'You need an internet connection. Your message stays in the form, so you can try again.',
          'You can send three messages per device per day. If you hit the limit, try again tomorrow.',
        ],
      },
      {
        heading: 'Prefer email?',
        paragraphs: [
          'You can always write to hello@thoughtreps.com. See [Support](/support) for more ways to reach us.',
        ],
      },
    ],
  },
  {
    slug: 'faq',
    category: 'your-data',
    title: 'Frequently asked questions',
    description:
      'Quick answers about accounts, offline use, why a new thought is not on your timeline, what opening a thought does, backups and more.',
    related: [
      'how-resurfacing-works',
      'privacy',
      'backup-and-restore',
      'themes',
    ],
    faq: true,
    sections: [
      {
        heading: 'Do I need an account?',
        paragraphs: [
          'No. There is nothing to sign up for or sign in to. Open the app and start writing.',
        ],
      },
      {
        heading: 'Where are my thoughts stored?',
        paragraphs: [
          'On your device only. An iPhone and an iPad each keep their own thoughts. See [Privacy: what stays on your phone](/help/privacy).',
        ],
      },
      {
        heading: 'Does it work offline?',
        paragraphs: [
          'Yes. Writing, reading, reminders, backups and imports all work with no connection. Only sending feedback and export links need the internet.',
        ],
      },
      {
        heading: 'Why is my new thought not on the timeline?',
        paragraphs: [
          'A new thought waits for its interval before it first shows. That is 7 days by default. You can find it any time. Tap {icon:search} on the Timeline to search every thought. Or open the {icon:hash} tab, pick a tag or "Untagged", and switch to "All". See [Search your thoughts](/help/search-your-thoughts) and [Understanding the timeline](/help/the-timeline).',
        ],
      },
      {
        heading: 'Can I change how long a thought waits?',
        paragraphs: [
          'Yes. Change the default in Settings, or give one thought its own interval. See [Snooze a thought or change its interval](/help/snooze-and-intervals).',
        ],
      },
      {
        heading: 'Can I change the look of the app?',
        paragraphs: [
          'Yes. Open Settings, tap "Theme" and pick one of six free themes. "Midnight" and "Terminal" are always dark. The others follow your device. See [Change the look with themes](/help/themes).',
        ],
      },
      {
        heading: 'Can I change the font of my thoughts?',
        paragraphs: [
          'Yes. Tap {icon:settings} on the Timeline to open Settings. Under "Appearance", set "Thought text" to "Paper Mono" or "System". It changes your thoughts, card previews, search results and the editor. Titles follow your theme. See [Change the look with themes](/help/themes).',
        ],
      },
      {
        heading: 'What happens if I miss a few days?',
        paragraphs: [
          'Thoughts that come due wait on your timeline until you deal with them. Their cards show how long they have waited, like "due 2d ago".',
        ],
      },
      {
        heading: 'Does opening a thought always count?',
        paragraphs: [
          'Yes, for any thought that is not archived and not in Learn mode. Opening it sends it back to wait for its next interval. A Learn thought moves only when you tap "Again" or "Got it". See [Learn mode](/help/learn-mode). The rest is true wherever you opened it from, even search results. Opening an archived thought does not requeue it. Editing the text does not, and neither does snoozing.',
        ],
      },
      {
        heading: 'Do I get a notification for every thought?',
        paragraphs: [
          'No. Reminders are off until you turn them on. The app offers once after your first thought, and you can change it any time in Settings. You get one reminder a day, at the time you pick. It says how many thoughts are back. Pinned thoughts are not counted, and the app never shows a badge on its icon. See [Set up a daily reminder](/help/daily-reminders).',
        ],
      },
      {
        heading: 'Why will a picture from a website not show?',
        paragraphs: [
          'Thought Reps only shows images you add to a thought from your own photos. It never loads pictures from the internet. See [Add images and galleries](/help/images-and-galleries).',
        ],
      },
      {
        heading: 'Can I search my thoughts?',
        paragraphs: [
          'Yes. Tap {icon:search} at the top right of the Timeline, or use the search box in the Archive tab. See [Search your thoughts](/help/search-your-thoughts).',
        ],
      },
      {
        heading: 'Does it sync between my devices?',
        paragraphs: [
          'No. To move your thoughts to another device, use a backup file or an export link. In Settings, "Import…" takes either one, with "From a File…" or "From a Link…". See [Back up and restore your thoughts](/help/backup-and-restore).',
        ],
      },
      {
        heading: 'Can I import notes from another app?',
        paragraphs: [
          'Not as an import. Thought Reps can only import its own backup files. You can share text, links and text or Markdown files from other apps into a new thought, though. See [Save from other apps](/help/save-from-other-apps).',
        ],
      },
      {
        heading: 'What happens if I delete the app?',
        paragraphs: [
          'Your thoughts are deleted with it, because they live on your phone. Make a backup first if you want to keep them.',
        ],
      },
      {
        heading: 'How do I contact you?',
        paragraphs: [
          'Use "Send Feedback" in Settings, or email hello@thoughtreps.com. See [Send feedback](/help/send-feedback).',
        ],
      },
    ],
  },
];

export const HELP_INDEX_PATH = '/help';

export interface HelpBreadcrumbItem {
  name: string;
  path: string;
}

export function helpArticlePath(slug: string): string {
  return `${HELP_INDEX_PATH}/${slug}`;
}

export function getHelpArticle(slug: string): HelpArticle | undefined {
  return HELP_ARTICLES.find((a) => a.slug === slug);
}

export function getArticlesInCategory(slug: HelpCategorySlug): HelpArticle[] {
  return HELP_ARTICLES.filter((a) => a.category === slug);
}

export function getRelatedArticles(article: HelpArticle): HelpArticle[] {
  return article.related.flatMap((slug) => getHelpArticle(slug) ?? []);
}

/** Drives both the visible breadcrumb and its BreadcrumbList structured data. */
export function getHelpBreadcrumb(article: HelpArticle): HelpBreadcrumbItem[] {
  return [
    { name: 'Help', path: HELP_INDEX_PATH },
    { name: article.title, path: helpArticlePath(article.slug) },
  ];
}

export type InlineToken =
  | { kind: 'text'; text: string }
  | { kind: 'code'; text: string }
  | { kind: 'link'; text: string; href: string }
  | { kind: 'icon'; name: HelpIconName; text: string; decorative: boolean };

const INLINE_PATTERN =
  /`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)|\{icon:([a-z-]+)(\|decorative)?\}/g;

export function parseInline(text: string): InlineToken[] {
  const tokens: InlineToken[] = [];
  let last = 0;
  for (const match of text.matchAll(INLINE_PATTERN)) {
    if (match.index > last) {
      tokens.push({ kind: 'text', text: text.slice(last, match.index) });
    }
    if (match[1] !== undefined) {
      tokens.push({ kind: 'code', text: match[1] });
    } else if (match[4] !== undefined) {
      tokens.push(
        isHelpIconName(match[4])
          ? {
              kind: 'icon',
              name: match[4],
              decorative: match[5] !== undefined,
              text: match[5] ? '' : HELP_ICONS[match[4]],
            }
          : { kind: 'text', text: match[0] },
      );
    } else {
      tokens.push({ kind: 'link', text: match[2], href: match[3] });
    }
    last = match.index + match[0].length;
  }
  if (last < text.length) {
    tokens.push({ kind: 'text', text: text.slice(last) });
  }
  return tokens;
}

export function toPlainText(text: string): string {
  return parseInline(text)
    .map((t) => t.text)
    .join('');
}

export interface FaqEntry {
  question: string;
  answer: string;
}

/** Questions and answers for an article with `faq: true`, as plain text. */
export function getFaqEntries(article: HelpArticle): FaqEntry[] {
  if (!article.faq) return [];
  return article.sections.map((section) => ({
    question: section.heading ?? '',
    answer: (section.paragraphs ?? []).map(toPlainText).join(' '),
  }));
}
