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

export interface HelpSection {
  heading?: string;
  paragraphs?: string[];
  steps?: string[];
  list?: string[];
}

export interface HelpArticle {
  slug: string;
  category: HelpCategorySlug;
  /** Page heading and the start of the <title>; keep it short enough for the suffix. */
  title: string;
  /** Meta description and the lede under the heading. */
  description: string;
  /** Slugs of 2 to 4 related articles. */
  related: string[];
  /**
   * When true, each section is a question (`heading`) and its answer
   * (`paragraphs`), and the page also gets FAQPage structured data.
   */
  faq?: boolean;
  /**
   * Text may use `code` and [link text](/help/slug). Nothing else is parsed.
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
      'Markdown, images, blurred blocks, tags and saving from other apps.',
  },
  {
    slug: 'reviewing',
    title: 'Reviewing',
    description:
      'Snooze, intervals, pinning, archiving and the daily reminder.',
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
      'Thought Reps is a notebook for iPhone that hands your ideas back to you. Write a thought, and it returns to your timeline after a week.',
    related: ['write-your-first-thought', 'how-resurfacing-works', 'privacy'],
    sections: [
      {
        paragraphs: [
          'Thought Reps is a notebook for iPhone. You write something down, and instead of disappearing into a long list of notes, it comes back to you later so you actually see it again.',
          'It works well for the things you want to remember but tend to forget: a quote you liked, an article you meant to read, a word of the day you are trying to learn, a question to think about.',
        ],
      },
      {
        heading: 'The basic loop',
        steps: [
          'Write a thought. It takes a few seconds, and you can use Markdown, images and #tags.',
          'Let it go. The thought leaves your timeline and waits for 7 days, or for whatever interval you set.',
          'Meet it again. When the time is up it shows on your timeline marked as due. Open it, and it heads out for another lap.',
        ],
      },
      {
        heading: 'What you get',
        list: [
          'Thoughts written in Markdown, with photos, image galleries and blurred blocks you can use to quiz yourself.',
          'Tags, with a timeline for each tag.',
          'Pin, snooze and archive to decide what stays in front of you.',
          'An optional daily reminder.',
          'A share option so you can save text and links from other apps.',
          'Backup files you own, and a one-time link for moving to another device.',
        ],
      },
      {
        heading: 'Private by design',
        paragraphs: [
          'There is no account. Your thoughts are stored on your iPhone, and the app works without an internet connection. Read [Privacy: what stays on your phone](/help/privacy) for the details.',
          'Thought Reps is made for iPhone and needs iOS 18 or later.',
        ],
      },
    ],
  },
  {
    slug: 'write-your-first-thought',
    category: 'getting-started',
    title: 'Write your first thought',
    description:
      'Tap the + button, type your thought, and save. Here is what happens next and where to find your thought while it waits.',
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
          'Tap the round + button at the bottom right. It is there on every tab.',
          'The "New thought" editor opens with the keyboard up. Type your thought.',
          'Tap "Save" at the top right. The button stays off until you have typed something.',
        ],
      },
      {
        paragraphs: [
          'To close the editor without saving, tap "Cancel". Once a new thought has text in it, swiping the editor down will not close it, so you do not lose a draft by accident.',
        ],
      },
      {
        heading: 'What the first line does',
        paragraphs: [
          'The first line of your thought becomes its title on the timeline. The next lines show underneath as a short preview. Heading marks such as `#` are removed from the title.',
        ],
      },
      {
        heading: 'Optional extras',
        list: [
          'Add `#tags` anywhere in the text to file the thought. See [Organize with tags](/help/tags).',
          'Add photos with the photo button above the keyboard. See [Add images and galleries](/help/images-and-galleries).',
          'Add a blurred block for an answer you want to hide. See [Quiz yourself with blurred blocks](/help/blurred-blocks).',
          'Under "Schedule", change "Comes back every" if this thought should return sooner or later than usual.',
        ],
      },
      {
        heading: 'Where does it go?',
        paragraphs: [
          'A saved thought waits before it first appears on the timeline, so it will not be there right away. That is intentional. To find it sooner, tap the magnifying glass on the Timeline and search for a word from it. See [Search your thoughts](/help/search-your-thoughts). [Understanding the timeline](/help/the-timeline) explains more.',
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
      'A thought waits, comes due, and returns to your timeline. Learn how the interval works and what opening, snoozing and archiving do.',
    related: [
      'the-timeline',
      'snooze-and-intervals',
      'pin-and-archive',
      'daily-reminders',
    ],
    sections: [
      {
        paragraphs: [
          'Every thought is in one of four states, and only two things move it between them: time passing, and what you do with it.',
        ],
      },
      {
        heading: 'The four states',
        list: [
          'Waiting. A new thought waits for its interval, counted from the moment you save it. By default that is 7 days. A waiting thought is not on your timeline.',
          'Due. When the waiting time is over, the thought shows on your timeline. The thought that has been due longest is listed first.',
          'Pinned. A pinned thought stays at the top of your timeline all the time, whether or not it is due.',
          'Archived. An archived thought never comes back on its own. It lives in the Archive tab until you restore it.',
        ],
      },
      {
        heading: 'What opening a thought does',
        paragraphs: [
          'Opening a thought counts as seeing it. It goes back to waiting, and its next due date is its interval counted from that moment. The card leaves your timeline when you go back to it, not while you are reading, so it will not vanish in the middle of a read.',
          'This is true wherever you open the thought from, including a tag page. Opening an archived thought does not requeue it.',
        ],
      },
      {
        heading: 'The interval',
        paragraphs: [
          'The default interval is 7 days. You can change the default in Settings, and you can give any single thought its own interval. See [Snooze a thought or change its interval](/help/snooze-and-intervals).',
        ],
      },
      {
        heading: 'If you miss a day',
        paragraphs: [
          'Nothing is lost. A thought that comes due stays on your timeline until you open it, snooze it or archive it, and its card tells you how long it has been waiting, for example "due 2d ago".',
        ],
      },
      {
        heading: 'Things that do not reset the timer',
        list: [
          'Editing the text of a thought.',
          'Snoozing. Snoozing pushes the due date forward without counting as a view.',
        ],
      },
    ],
  },
  {
    slug: 'the-timeline',
    category: 'getting-started',
    title: 'Understanding the timeline',
    description:
      'The Timeline tab shows pinned thoughts and thoughts that are due. Learn what each card shows and how to see every thought, including waiting ones.',
    related: [
      'search-your-thoughts',
      'how-resurfacing-works',
      'pin-and-archive',
      'tags',
    ],
    sections: [
      {
        paragraphs: [
          'The app has three tabs: Timeline, Tags and Archive. The Timeline is the first one, and it only shows what needs your attention today.',
        ],
      },
      {
        heading: 'What is on the Timeline',
        list: [
          'A "Pinned" section at the top, with every pinned thought.',
          'A "Due" section below it, with thoughts whose waiting time is over, oldest first.',
        ],
      },
      {
        paragraphs: [
          'Thoughts that are still waiting are not shown here. When nothing is due, the Timeline says "All caught up" and tells you what is coming next, such as "3 thoughts come back tomorrow."',
        ],
      },
      {
        heading: 'Reading a card',
        list: [
          'The title is the first line of the thought, and the preview is the lines after it.',
          'Tag chips show which tags the thought has.',
          'A small thumbnail appears on the right if the thought has an image.',
          'A label such as "due today" or "due 2d ago" shows how long it has been due. Pinned thoughts show a pin icon instead.',
        ],
      },
      {
        heading: 'Quick actions',
        list: [
          'Swipe right on a card to pin it, or unpin it if it is already pinned.',
          'Swipe left to archive it, or tap "Tomorrow" to snooze it for a day. On a pinned card the second button is "Unpin".',
          'Pull down to refresh the list.',
          'At the top right, tap the magnifying glass to search, or the gear icon next to it to open Settings.',
        ],
      },
      {
        heading: 'Seeing every thought',
        paragraphs: [
          'The Timeline is not a list of everything you have written. To find a particular thought, tap the magnifying glass and search. See [Search your thoughts](/help/search-your-thoughts). To browse instead, open the Tags tab and pick a tag, or "Untagged" for thoughts with no tag. Each of those pages has a "Due" and "All" switch at the top right, and "All" shows every thought that is not archived, whether it is due or not.',
        ],
      },
    ],
  },
  {
    slug: 'search-your-thoughts',
    category: 'getting-started',
    title: 'Search your thoughts',
    description:
      'Find any thought, whether it is due, waiting, pinned or archived. Search covers your text, blurred blocks, gallery titles and tags.',
    related: [
      'the-timeline',
      'tags',
      'pin-and-archive',
      'how-resurfacing-works',
    ],
    sections: [
      {
        paragraphs: [
          'Search finds a thought by its words, including thoughts that are still waiting and do not show on your Timeline yet.',
        ],
      },
      {
        heading: 'Open search',
        steps: [
          'On the Timeline, tap the magnifying glass at the top right, next to the gear icon.',
          'The "Search" screen opens with the "Search thoughts" box ready for typing.',
          'Type at least 2 characters. Results appear as you type.',
        ],
      },
      {
        heading: 'What is searched',
        list: [
          'The text of your thoughts, without the Markdown symbols.',
          'The text of blurred blocks, so a hidden answer can be found too.',
          'The titles of image galleries.',
          'Tag names.',
        ],
      },
      {
        heading: 'How matching works',
        list: [
          'Capital letters and accents do not matter.',
          'Each word you type matches the start of a word, so "reflec" finds "reflection".',
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
          'Each result shows the title, a snippet around the match, the tag chips, and where the thought stands: "Due", "Back later today", "Back in 3 days" or "Archived". Pinned thoughts show a pin icon instead.',
        ],
      },
      {
        heading: 'Opening a result',
        paragraphs: [
          'Tap a result to open the thought. As with any thought, opening one that is not archived counts as seeing it, so it goes back to waiting for its next interval. Opening an archived thought does not requeue it. See [How resurfacing works](/help/how-resurfacing-works).',
        ],
      },
      {
        heading: 'Search in the Archive',
        paragraphs: [
          'The Archive tab has its own "Search archive" box that searches archived thoughts. In its results you can still swipe right to restore a thought or swipe left to delete it.',
        ],
      },
      {
        heading: 'Good to know',
        list: [
          'Search runs on your phone and works offline.',
          'If you see "Indexing… results may be incomplete.", Thought Reps is still updating its search list, which can happen shortly after the app starts. Results fill in when it finishes.',
          'The search list is rebuilt by the app itself, and it is not part of your backup file.',
        ],
      },
    ],
  },
  {
    slug: 'markdown-formatting',
    category: 'writing',
    title: 'Format your thoughts with Markdown',
    description:
      'Use the formatting bar above the keyboard or type Markdown yourself. See what each button adds and what Thought Reps can display.',
    related: ['images-and-galleries', 'tags', 'blurred-blocks'],
    sections: [
      {
        paragraphs: [
          'Markdown is a way to add formatting by typing a few plain characters. You type it in the editor, and the formatted result appears when you open the thought. You never have to learn it, because the editor has buttons for the common cases.',
        ],
      },
      {
        heading: 'The formatting bar',
        paragraphs: [
          'While you type, a row of buttons sits above the keyboard. With some text selected, a button wraps it. With nothing selected it inserts an empty pair and puts the cursor in the middle. Tapping the same button again removes the formatting.',
        ],
        list: [
          'Heading adds `# ` at the start of the line.',
          'Bold wraps text in `**double asterisks**`.',
          'Italic wraps text in `_underscores_`.',
          'List adds `- ` at the start of the line.',
          'Task adds `- [ ] `, which shows as a checklist item.',
          'Code wraps text in backticks.',
          'Tag inserts a `#` and shows your existing tags to pick from.',
          'The photo button adds an image. See [Add images and galleries](/help/images-and-galleries).',
        ],
      },
      {
        heading: 'Lists keep going',
        paragraphs: [
          'When you press return at the end of a bullet, numbered or task item, the next item starts for you. Press return on an empty item to end the list.',
        ],
      },
      {
        heading: 'What you can write',
        list: [
          'Headings, bold and italic.',
          'Strikethrough, written with `~~two tildes~~` on each side.',
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
          'The editor shows plain Markdown text. Open the thought to see it formatted.',
          'Text in a thought can be selected and copied.',
          'Blurred text blocks are plain text, so Markdown does not apply inside them.',
        ],
      },
    ],
  },
  {
    slug: 'images-and-galleries',
    category: 'writing',
    title: 'Add images and galleries',
    description:
      'Put photos in the middle of a thought or collect several in a gallery. Learn how to add, view and remove them, and what happens to the file.',
    related: ['markdown-formatting', 'blurred-blocks', 'backup-and-restore'],
    sections: [
      {
        paragraphs: [
          'There are two ways to add pictures to a thought: inside the text, or as a gallery under it.',
        ],
      },
      {
        heading: 'Images inside the text',
        steps: [
          'In the editor, tap the photo button in the row above the keyboard.',
          'Choose "Photo Library" or "Take Photo". "Paste Image" is offered when you have copied a picture.',
          'The picture is added where your cursor is, as a line of text like `![](img:…)`. A small thumbnail appears under the text box.',
        ],
      },
      {
        paragraphs: [
          'That line is the image, so cut and paste it to move the picture, or delete it to remove the picture. You can also tap the x on its thumbnail under the text box.',
        ],
      },
      {
        heading: 'Galleries',
        paragraphs: [
          'A gallery is a row of pictures that scrolls sideways under your thought.',
        ],
        steps: [
          'In the editor, scroll to the "Blocks" section and tap "Add block".',
          'Choose "Image gallery".',
          'Type an optional title, then tap the + tile to add one or more images.',
        ],
      },
      {
        paragraphs: [
          'A gallery needs at least one image. If you leave one empty, it is not saved.',
        ],
      },
      {
        heading: 'Viewing images',
        paragraphs: [
          "Tap any image in a thought to open it full screen. Swipe sideways to move between the thought's images, pinch or double-tap to zoom, and tap the x at the top right to close.",
        ],
      },
      {
        heading: 'What happens to your pictures',
        list: [
          'Large photos are resized so the longest side is at most 2048 pixels, which keeps the app light.',
          'All metadata is removed from the copy Thought Reps keeps, including where and when the photo was taken.',
          'Images stay on your iPhone and are included in your backup files.',
          'Only photos you add are shown. A picture linked from a website will not load.',
        ],
      },
      {
        heading: 'Camera access',
        paragraphs: [
          'The first time you choose "Take Photo", iOS asks whether Thought Reps may use the camera. It is only used to take photos for your thoughts.',
        ],
      },
    ],
  },
  {
    slug: 'blurred-blocks',
    category: 'writing',
    title: 'Quiz yourself with blurred blocks',
    description:
      'A blurred block hides text until you tap it. Put a question in your thought and the answer in a block to test yourself each time it returns.',
    related: [
      'write-your-first-thought',
      'markdown-formatting',
      'how-resurfacing-works',
    ],
    sections: [
      {
        paragraphs: [
          'A blurred block is a piece of text that stays hidden behind a heavy blur until you tap it. It turns a thought into a small quiz: write the question in the thought, put the answer in a blurred block, and try to recall it before you reveal it.',
          'It is a good fit for words of the day, definitions, names, quotes you want to complete, and anything you want to learn rather than just read.',
        ],
      },
      {
        heading: 'Add a blurred block',
        steps: [
          'In the editor, scroll to the "Blocks" section and tap "Add block".',
          'Choose "Blurred text".',
          'Optionally type a label, such as "Answer". If you leave it empty, the block is called "Hidden".',
          'Type the text to hide in the "Hidden text" field.',
        ],
      },
      {
        paragraphs: [
          'You can add as many blocks as you like. A blurred block with no text is dropped when you save. To remove a block, swipe it left in the editor.',
        ],
      },
      {
        heading: 'Using it',
        paragraphs: [
          'Blocks appear under the body of the thought. The block shows its label and "Tap to reveal". Tap it to see the text, and tap again to hide it ("Hide").',
          'The block is hidden again every time you open the thought, so each visit is a fresh recall.',
        ],
      },
      {
        heading: 'Example',
        list: [
          'Thought: "Word of the day: petrichor. What does it mean?"',
          'Blurred block labelled "Answer": "The smell of rain on dry ground."',
        ],
      },
      {
        heading: 'Good to know',
        list: [
          'The hidden text is plain text. Markdown formatting does not apply inside a block.',
          'Blurred blocks are included in backups.',
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
      'markdown-formatting',
    ],
    sections: [
      {
        heading: 'Make a tag',
        paragraphs: [
          'Type a `#` followed by a word anywhere in your thought, for example `#quotes` or `#to-read`. That is all it takes. The editor lists the tags it found under the text box.',
          'Tags can contain letters, numbers, underscores and hyphens, and must include at least one letter, so `#1` is not a tag.',
        ],
      },
      {
        heading: 'Rules worth knowing',
        list: [
          'Tags are not case sensitive. `#Quotes` and `#quotes` are the same tag, and the first spelling you used is the one shown.',
          'A heading such as `# Title` is a heading, not a tag.',
          'A `#` inside a web address, inside code, or right after a letter (as in C#) is not a tag.',
          'Tags are read again every time you save, so deleting `#quotes` from the text removes the tag from that thought.',
        ],
      },
      {
        heading: 'Pick from your existing tags',
        paragraphs: [
          'When you type a `#`, the row above the keyboard offers your existing tags, with how many thoughts use each. Tap one to complete it. The Tag button on the formatting bar inserts a `#` for you.',
        ],
      },
      {
        heading: 'The Tags tab',
        list: [
          'Every tag is listed with the number of thoughts that have it, and a "due" count when some of them are due.',
          '"Untagged" collects thoughts that have no tag.',
          'Use the search box, labelled "Filter tags", to find a tag by name.',
          'Tap a tag to open its page. It works like the Timeline but only for that tag, with a "Due" and "All" switch at the top.',
        ],
      },
      {
        heading: 'Jumping to a tag',
        paragraphs: [
          "Tap a tag chip on a thought, or a tag written in its text, to go straight to that tag's page.",
          "If you tap the + button while on a tag's page, the new thought starts with that tag already filled in.",
        ],
      },
      {
        paragraphs: [
          'Tag counts only include thoughts that are not archived. A tag disappears from the list when no thought uses it any more.',
        ],
      },
    ],
  },
  {
    slug: 'save-from-other-apps',
    category: 'writing',
    title: 'Save from other apps',
    description:
      'Send text, a link or a Markdown file to Thought Reps from Safari, Notes or any app with a share button. It appears in your app the next time you open it.',
    related: ['write-your-first-thought', 'the-timeline', 'tags'],
    sections: [
      {
        paragraphs: [
          'You can send things to Thought Reps without opening it, using the share button in other apps.',
        ],
      },
      {
        heading: 'What you can share',
        list: [
          'Text you have selected, such as a quote from an article.',
          'A web link, for example the page you are reading in Safari.',
          'A single text or Markdown file, up to 1 MB.',
        ],
      },
      {
        paragraphs: [
          'Photos, and several files or links at once, cannot be shared in.',
        ],
      },
      {
        heading: 'How to share',
        steps: [
          'Tap the share button in the other app.',
          'Choose Thought Reps. If you do not see it, scroll to the end of the row of apps, tap "More", and turn it on.',
          'A "New Thought" screen opens with what you shared already filled in. If you shared text and a link, the link goes on its own line under the text.',
          'Edit it if you like, and add any #tags. Then tap "Save", or "Cancel" to throw it away.',
        ],
      },
      {
        heading: 'Where it goes',
        paragraphs: [
          'The thought is saved in a hand-off folder and added to Thought Reps the next time you open the app. It then behaves like any other thought: it waits for the default interval before it shows on your timeline. You can find it sooner with the magnifying glass on the Timeline. See [Search your thoughts](/help/search-your-thoughts) and [Understanding the timeline](/help/the-timeline).',
        ],
      },
      {
        heading: 'If a file cannot be read',
        paragraphs: [
          'Thought Reps will tell you if a shared file is larger than 1 MB or is not UTF-8 text. Sharing text or a link instead always works.',
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
      'Push a thought back by a day or a week, or choose how often it returns: a default for everything, or a custom interval for one thought.',
    related: [
      'how-resurfacing-works',
      'pin-and-archive',
      'the-timeline',
      'daily-reminders',
    ],
    sections: [
      {
        heading: 'Snooze',
        paragraphs: [
          "Snoozing pushes a thought's return date forward without counting as a view. Use it when you are not ready for a thought today.",
        ],
        list: [
          'On the Timeline, swipe left on a card and tap "Tomorrow".',
          'Inside a thought, tap the More button (three dots in a circle) at the top right and choose "Snooze until tomorrow" or "Snooze a week". The thought closes.',
        ],
      },
      {
        heading: 'The default interval',
        paragraphs: [
          'Open Settings from the gear icon on the Timeline. Under "Resurfacing", "Default interval" sets how long a thought waits. It starts at 7 days and can be anything from 1 to 90 days.',
          'The default applies to thoughts that do not have their own interval, and to future views. It does not move the due dates thoughts already have.',
        ],
      },
      {
        heading: 'An interval for one thought',
        paragraphs: [
          'Some thoughts deserve a different rhythm. A word you are memorizing might come back every day, while a quote might come back every month.',
        ],
        list: [
          'In the editor, under "Schedule", use the "Comes back every" menu.',
          'On an open thought, use the menu at the bottom right that reads like "Every week".',
        ],
      },
      {
        paragraphs: [
          'The menu offers "Default", Day, 3 days, Week, 2 weeks, Month and 3 months, plus "Custom…" for anything else. Custom opens a wheel where you pick a number and days, weeks or months, up to a year.',
        ],
      },
      {
        heading: 'What changing an interval does',
        paragraphs: [
          "When you change a thought's interval, the new interval is counted from the last time you opened it, or from when you wrote it if you have never opened it. A shorter interval can therefore make a thought due straight away.",
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
          'A pinned thought stays in the "Pinned" section at the top of your Timeline all the time, whether or not it is due. It is good for things you want to see every day, like a set of weekly review questions.',
        ],
        list: [
          'Swipe right on a card on the Timeline.',
          'Or tap the pin icon at the top of an open thought.',
        ],
      },
      {
        paragraphs: [
          'To unpin, do the same again, or swipe left on the card and tap "Unpin". Pinned thoughts are not counted in your daily reminder.',
        ],
      },
      {
        heading: 'Archive a thought',
        paragraphs: [
          'Archive a thought when you are finished with it. It leaves the Timeline and your tag pages and never comes back on its own. Archiving also unpins it.',
        ],
        list: [
          'Swipe left on a card and tap "Archive".',
          'Or open the thought, tap the More button (three dots in a circle) at the top right, and choose "Archive".',
        ],
      },
      {
        heading: 'The Archive tab',
        list: [
          'Archived thoughts are listed newest first, with the date they were archived.',
          'Use the "Search archive" box to find an old thought. See [Search your thoughts](/help/search-your-thoughts).',
          'Swipe right on one to restore it.',
          'Opening an archived thought does not requeue it.',
        ],
      },
      {
        heading: 'Restore',
        paragraphs: [
          'A restored thought is due immediately, so it shows on your Timeline straight away. You can also restore from inside the thought, with the More button and then "Restore".',
        ],
      },
      {
        heading: 'Delete',
        paragraphs: [
          'Delete removes a thought for good, along with its images and blocks. In the Archive, swipe left on a thought and tap "Delete". Inside a thought, the More button also has "Delete", which asks you to confirm. Deleting cannot be undone, so archive instead if you might want it back.',
        ],
      },
    ],
  },
  {
    slug: 'daily-reminders',
    category: 'reviewing',
    title: 'Set up a daily reminder',
    description:
      'Turn on one notification a day, at a time you choose, when thoughts are back. Learn how it counts, what it says and how to fix denied permissions.',
    related: ['how-resurfacing-works', 'pin-and-archive', 'privacy'],
    sections: [
      {
        heading: 'Turn it on',
        steps: [
          'Tap the gear icon on the Timeline to open Settings.',
          'Under "Reminder", turn on "Daily reminder".',
          'The first time, iOS asks if Thought Reps may send notifications. Choose Allow.',
          'Pick a time with the "Time" row. The default is 8:00 AM.',
        ],
      },
      {
        heading: 'What the reminder says',
        paragraphs: [
          'The notification is from "Thought Reps" and reads, for example, "3 thoughts are back today", or "1 thought is back today". Tapping it opens your Timeline.',
        ],
      },
      {
        heading: 'When it is sent',
        list: [
          'You get at most one reminder a day, at your chosen time.',
          'No thoughts due means no reminder that day.',
          'The count includes thoughts that are due by that time, including ones that have been waiting a while.',
          'Pinned and archived thoughts are never counted.',
        ],
      },
      {
        heading: 'If you are away for a while',
        paragraphs: [
          'The app plans your reminders ahead of time and refreshes the plan whenever you open it or leave it. If you stay away, a few follow-up reminders arrive about 2 weeks, a month and 3 months later, reading "N thoughts are waiting for you". After that the reminders stop until you open the app again.',
        ],
      },
      {
        heading: 'If it does not work',
        paragraphs: [
          'If you turned notifications off for Thought Reps in iOS, Settings shows "Notifications are off for Thought Reps in iOS Settings" and an "Open Settings" button. Turn notifications on there, then switch "Daily reminder" on again.',
        ],
      },
      {
        heading: 'Local only',
        paragraphs: [
          'Reminders are made on your iPhone. They are not sent from a server, and the app never puts a number badge on its icon.',
        ],
      },
    ],
  },
  {
    slug: 'privacy',
    category: 'your-data',
    title: 'Privacy: what stays on your phone',
    description:
      'Thought Reps has no account and keeps your thoughts on your iPhone. See when the app uses the internet and what is, and is not, ever sent.',
    related: ['move-to-a-new-phone', 'send-feedback', 'backup-and-restore'],
    sections: [
      {
        heading: 'Your thoughts stay on your phone',
        paragraphs: [
          'There is no account and nothing to sign in to. Your thoughts, images, tags and settings are stored on your iPhone. The app works without an internet connection.',
        ],
      },
      {
        heading: 'When the app uses the internet',
        paragraphs: ['Only for two things you start yourself:'],
        list: [
          'Sending feedback.',
          'Creating, checking or revoking an export link.',
        ],
      },
      {
        paragraphs: [
          "The share option does not use the internet, and notifications are made on your phone. Requests to our service are signed with Apple's App Attest, which lets us accept them only from a real copy of the app.",
        ],
      },
      {
        heading: 'Feedback',
        paragraphs: [
          'A feedback message includes what you wrote, your email address so we can reply, and your app version, iOS version and device model. It never includes your thoughts. See [Send feedback](/help/send-feedback).',
        ],
      },
      {
        heading: 'Export links',
        paragraphs: [
          'If you share an export as a link, your backup file is encrypted on your iPhone with AES-256-GCM before it is uploaded. The key is in the part of the link after the `#`, which web browsers never send to a server. So the file we hold is unreadable to us. The file is deleted after one download, or after 24 hours, and you can revoke the link in Settings. See [Move to a new phone with an export link](/help/move-to-a-new-phone).',
        ],
      },
      {
        heading: 'Backups are yours',
        paragraphs: [
          'A backup file goes where you put it: Files, AirDrop, iCloud Drive or anywhere else you share it. Anyone who has the file can read it, so keep it somewhere you trust.',
          'Because your thoughts live on your phone, deleting the app deletes them. Make a backup first if you want to keep them. See [Back up and restore your thoughts](/help/backup-and-restore).',
        ],
      },
      {
        heading: 'Questions',
        paragraphs: ['Email hello@thoughtreps.com.'],
      },
    ],
  },
  {
    slug: 'backup-and-restore',
    category: 'your-data',
    title: 'Back up and restore your thoughts',
    description:
      'Export every thought, tag and image to a .thoughtreps file you keep, and import it later. Importing merges, keeping the newer version of each thought.',
    related: ['move-to-a-new-phone', 'privacy', 'faq'],
    sections: [
      {
        paragraphs: [
          'A backup is a single file with the extension `.thoughtreps`. It holds all your thoughts, their tags, blocks and images, and whether each is pinned or archived. It does not hold your app settings, such as the default interval and reminder time.',
        ],
      },
      {
        heading: 'Make a backup',
        steps: [
          'Tap the gear icon on the Timeline to open Settings.',
          'In the "Backup" section, tap "Export…". A progress bar shows while the file is built.',
          'The iOS share sheet opens. Save the file to Files or iCloud Drive, AirDrop it, or send it wherever you like.',
        ],
      },
      {
        paragraphs: [
          'The file is named like `ThoughtReps-export-2026-10-05.thoughtreps`, with the date you made it. A big library with lots of images can take a little while to export, so give it a moment.',
        ],
      },
      {
        heading: 'Restore from a backup',
        steps: [
          'In Settings, under "Backup", tap "Import…", then choose your `.thoughtreps` file.',
          'Thought Reps checks the file and shows a summary, such as "12 thoughts · 3 images — 5 new, 2 newer, 5 already up to date".',
          'Tap "Import". When it is done you see how many thoughts were imported.',
        ],
      },
      {
        paragraphs: [
          'You can also open a `.thoughtreps` file from Files or AirDrop and choose Thought Reps to start the same steps.',
        ],
      },
      {
        heading: 'How importing merges',
        list: [
          'Thoughts that are new to this phone are added.',
          'If a thought is already on this phone, the version that was edited more recently is kept.',
          'Nothing on your phone is deleted by an import, and importing the same file twice changes nothing.',
          'Imported thoughts keep their schedule, pins and archive state.',
        ],
      },
      {
        heading: 'Good to know',
        list: [
          'Thought Reps can only import its own backup files, not files from other apps.',
          'Only one export or import can run at a time.',
          'If an import is interrupted, run it again. It picks up what is missing.',
        ],
      },
    ],
  },
  {
    slug: 'move-to-a-new-phone',
    category: 'your-data',
    title: 'Move to a new phone with an export link',
    description:
      'Share your backup as a one-time link that works for 24 hours. It is encrypted on your iPhone first, so only the link can open it.',
    related: ['backup-and-restore', 'privacy', 'faq'],
    sections: [
      {
        paragraphs: [
          'An export link is a way to get your thoughts onto another device when AirDrop or iCloud Drive is not handy, for example when you are moving to a new phone or want the file on a computer first. If you can AirDrop the file, [a regular backup](/help/backup-and-restore) is simpler.',
        ],
      },
      {
        heading: 'Create a link',
        steps: [
          'Open Settings, then go to the "Backup" section.',
          'Tap "Share export as link". Thought Reps builds your backup, encrypts it and uploads it.',
          'When it is ready, the link appears with its expiry time. Tap "Copy link" or "Share link".',
        ],
      },
      {
        heading: 'Open it on your new phone',
        steps: [
          'Open the link in a browser. The page is titled "Your Thought Reps export".',
          'Tap "Download". The file is unlocked in your browser and saved as a `.thoughtreps` file.',
          'On an iPhone, open the saved file with Thought Reps and import it. If you downloaded on a computer, send the file to your phone first, for example with AirDrop or Files.',
        ],
      },
      {
        paragraphs: [
          'Install Thought Reps on the new phone first. See [Back up and restore your thoughts](/help/backup-and-restore) for the import steps.',
        ],
      },
      {
        heading: 'How the link behaves',
        list: [
          'It works once. The first download uses it up. Simply opening the page does not.',
          'It expires after 24 hours if nobody uses it.',
          'You have one open link at a time. Creating a new one replaces the old one, and you are asked to confirm.',
          'The exported file can be up to 100 MB. For something larger, use "Export…" and send the file.',
          'There is a daily limit on how many links you can create.',
        ],
      },
      {
        heading: 'Revoke a link',
        paragraphs: [
          'The open link stays in Settings, with its expiry time, until it is used or expires. Tap "Revoke link" to stop it working right away.',
        ],
      },
      {
        heading: 'Keeping it private',
        paragraphs: [
          'Your file is encrypted on your iPhone before upload, and the key is only in the link after the `#`, which browsers do not send to us. We cannot read what you upload. That also means anyone with the whole link can download the file once, so only send it to yourself. A copied link also leaves your clipboard when it expires.',
        ],
      },
    ],
  },
  {
    slug: 'send-feedback',
    category: 'your-data',
    title: 'Send feedback',
    description:
      'Request a feature or report a problem from Settings. Your message goes straight to us with your email, and never includes your thoughts.',
    related: ['privacy', 'faq'],
    sections: [
      {
        heading: 'How to send it',
        steps: [
          'Tap the gear icon on the Timeline to open Settings.',
          'Under "Send Feedback", tap "Request a Feature" or "Report a Problem".',
          'Write your message. It can be up to 5,000 characters, and a counter shows how many you have used.',
          'Enter your email so we can reply. The app remembers it for next time.',
          'Tap "Send". You see "Thanks for your feedback" when it has gone through.',
        ],
      },
      {
        heading: 'What is included',
        paragraphs: [
          'The form lists what is sent along with your message: your app version, iOS version and device model. Your thoughts are never attached.',
        ],
      },
      {
        heading: 'If it does not send',
        list: [
          'You need an internet connection. Your message stays in the form, so you can try again.',
          'There is a limit of three messages per device per day. If you hit it, try again tomorrow.',
        ],
      },
      {
        heading: 'Prefer email?',
        paragraphs: ['You can always write to hello@thoughtreps.com.'],
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
      'send-feedback',
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
          'On your iPhone only. See [Privacy: what stays on your phone](/help/privacy).',
        ],
      },
      {
        heading: 'Does it work offline?',
        paragraphs: [
          'Yes. Writing, reading, reminders, backups and imports all work without a connection. Only sending feedback and export links need the internet.',
        ],
      },
      {
        heading: 'Why is my new thought not on the timeline?',
        paragraphs: [
          'A new thought waits for its interval, 7 days by default, before it first appears. You can find it any time with the magnifying glass on the Timeline, which searches every thought, or in the Tags tab using the "All" view. See [Search your thoughts](/help/search-your-thoughts) and [Understanding the timeline](/help/the-timeline).',
        ],
      },
      {
        heading: 'Can I change how long a thought waits?',
        paragraphs: [
          'Yes. Change the default in Settings, or give one thought its own interval. See [Snooze a thought or change its interval](/help/snooze-and-intervals).',
        ],
      },
      {
        heading: 'What happens if I miss a few days?',
        paragraphs: [
          'Thoughts that come due wait on your timeline until you deal with them, and their cards show how long they have been waiting, such as "due 2d ago".',
        ],
      },
      {
        heading: 'Does opening a thought always count?',
        paragraphs: [
          'Yes, for any thought that is not archived. Opening it sends it back to wait for its next interval, wherever you opened it from, including from search results. Opening an archived thought does not requeue it. Editing the text does not, and neither does snoozing.',
        ],
      },
      {
        heading: 'Do I get a notification for every thought?',
        paragraphs: [
          'No. You can turn on one reminder a day, at the time you choose, that says how many thoughts are back. Pinned thoughts are not counted, and the app never shows a badge on its icon. See [Set up a daily reminder](/help/daily-reminders).',
        ],
      },
      {
        heading: 'Why will a picture from a website not show?',
        paragraphs: [
          'Thought Reps only shows images you add to a thought from your own photos, and never loads pictures from the internet. See [Add images and galleries](/help/images-and-galleries).',
        ],
      },
      {
        heading: 'Can I search my thoughts?',
        paragraphs: [
          'Yes. Tap the magnifying glass at the top right of the Timeline, or use the search box in the Archive tab. See [Search your thoughts](/help/search-your-thoughts).',
        ],
      },
      {
        heading: 'Does it sync between my devices?',
        paragraphs: [
          'No. To move your thoughts to another device, use a backup file or an export link. See [Back up and restore your thoughts](/help/backup-and-restore).',
        ],
      },
      {
        heading: 'Can I import notes from another app?',
        paragraphs: [
          'Not as an import. Thought Reps can only import its own backup files. You can, however, share text, links and text or Markdown files from other apps into a new thought. See [Save from other apps](/help/save-from-other-apps).',
        ],
      },
      {
        heading: 'What happens if I delete the app?',
        paragraphs: [
          'Your thoughts are deleted with it, because they are stored on your phone. Make a backup first if you want to keep them.',
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
  | { kind: 'link'; text: string; href: string };

const INLINE_PATTERN = /`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)/g;

export function parseInline(text: string): InlineToken[] {
  const tokens: InlineToken[] = [];
  let last = 0;
  for (const match of text.matchAll(INLINE_PATTERN)) {
    if (match.index > last) {
      tokens.push({ kind: 'text', text: text.slice(last, match.index) });
    }
    if (match[1] !== undefined) {
      tokens.push({ kind: 'code', text: match[1] });
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
