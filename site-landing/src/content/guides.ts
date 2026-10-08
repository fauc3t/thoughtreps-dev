// Source of truth for /guides: longer reads on the ideas behind Thought Reps,
// written for people who haven't heard of the app yet (help.ts is for people
// using it). The hub, routes, sitemap, structured data and link-preview cards
// are generated from GUIDES, so adding a guide is one edit here.
//
// Guides share the help center's section format and inline syntax (`code`,
// [links](/help/slug), {icon:name}), and the same rule: only describe what the
// shipped app does.

import type { HelpSection } from './help';

export interface Guide {
  slug: string;
  /** Page heading and the start of the <title>; keep it short enough for the suffix. */
  title: string;
  /** Meta description and the lede under the heading. Plain text only. */
  description: string;
  /** ISO date, shown on the page and in the Article structured data. */
  published: string;
  /** ISO date of the last real content change, if any. */
  updated?: string;
  /** Slugs of 2 to 4 help articles to read next. */
  relatedHelp: string[];
  sections: HelpSection[];
}

export const GUIDES: Guide[] = [
  {
    slug: 'digital-commonplace-book',
    title: 'How to keep a digital commonplace book',
    description:
      'A commonplace book is a notebook of quotes and ideas worth keeping. Where the habit comes from, why most fail, and how to keep one you reread.',
    published: '2026-10-08',
    relatedHelp: [
      'what-is-thought-reps',
      'how-resurfacing-works',
      'tags',
      'save-from-other-apps',
    ],
    sections: [
      {
        paragraphs: [
          'A commonplace book is a notebook for the lines and ideas you want to keep. A quote from a book. Something a friend said. A lesson you learned the hard way. A half-formed thought you had on the bus. They all go in one place, so you can find them and read them again.',
          'People have kept them for about 500 years. This guide covers what a commonplace book is, where the idea comes from, why most of them fail, and how to keep one on your phone.',
        ],
      },
      {
        heading: 'What a commonplace book is',
        paragraphs: [
          'It is not a diary. A diary is sorted by date, and it is about your day. A commonplace book is sorted by idea, and it is about what is worth keeping. Here is how it compares:',
        ],
        list: [
          'A diary: what happened today, in date order.',
          'Class notes: one course or one book, and then you stop.',
          'A commonplace book: anything worth keeping, from any source, for life.',
        ],
      },
      {
        paragraphs: [
          'The best ones mix other people’s words with your own. You copy a line, then add a sentence on why it stuck with you. Over time, the notes you add are worth as much as the quotes.',
        ],
      },
      {
        heading: 'Where the name comes from',
        paragraphs: [
          'The name comes from the Latin "locus communis", which means a "common place". In old schools of public speaking, that was a stock theme a speaker could draw on, like friendship, luck or death. Students gathered good lines under each theme, so they always had something to say.',
          'In 1512 the Dutch scholar Erasmus told students to keep a notebook with headings, and to copy what they read under the right one. The habit spread through the schools of Europe. The poet John Milton kept one. So did Thomas Jefferson. The thinker John Locke even wrote up his own way to index one, so any entry could be found fast. It came out in French in 1686 and in English in 1706.',
        ],
      },
      {
        heading: 'Why most commonplace books fail',
        paragraphs: [
          'Writing things down is the easy part. The hard part is reading them again. A notebook on a shelf, or a notes app with two thousand notes, only gives back what you go looking for. Most entries are never seen again.',
          'And what you don’t see again, you tend to forget. The old keepers knew this. They went back through their books on purpose, and they built indexes so they could find things. Most of us don’t have time for that. So the notebook fills up, and the ideas in it fade.',
        ],
      },
      {
        heading: 'How to keep one on your iPhone',
        paragraphs: [
          'Thought Reps is a notebook built around that missing step. You write something down, and a week later it comes back to you on your timeline. Read it, and it goes off to wait another week. You don’t have to remember to reread. Your entries show up on their own.',
        ],
        steps: [
          'Tap {icon:plus} on the Timeline and write the line or idea. Say where it came from.',
          'Under it, add a note of your own: why it matters, or where you might use it.',
          'Add a tag or two, like `#quotes` or `#work`. Tags are your headings.',
          'Close it and get on with your day. In 7 days it comes back on your timeline.',
          'When it is back, open it and read it. That sends it off to wait again.',
        ],
        example: {
          kind: 'timeline',
          caption:
            'Entries come back on the timeline when they are due, so you reread them without trying.',
        },
      },
      {
        paragraphs: [
          'Seven days is the default. You can change it for the whole app, or give one entry its own wait. See [Snooze a thought or change its interval](/help/snooze-and-intervals).',
        ],
      },
      {
        heading: 'Tags are your headings',
        paragraphs: [
          'Erasmus used headings. In Thought Reps, you use tags. Type `#quotes` or `#stoic` anywhere in a thought, and it is filed under that tag. The {icon:hash} tab lists every tag, so you can read all your entries on one theme.',
          'Search does the job of Locke’s index. Tap {icon:search} on the Timeline to find any entry by a word in it. See [Organize with tags](/help/tags) and [Search your thoughts](/help/search-your-thoughts).',
        ],
        example: {
          kind: 'tag-list',
          caption:
            'The Tags tab works like the headings in an old commonplace book.',
        },
      },
      {
        heading: 'What to put in it',
        list: [
          'Quotes from books, with the title and author.',
          'Lines from talks, podcasts and sermons.',
          'Things people said to you that stuck.',
          'Lessons from mistakes, written as advice to your future self.',
          'Your own ideas, even the half-formed ones.',
          'Words you want to learn, and what they mean.',
          'Questions you can’t answer yet.',
        ],
      },
      {
        paragraphs: [
          'You can also send text and links from other apps straight into a new thought with the share sheet. See [Save from other apps](/help/save-from-other-apps).',
        ],
      },
      {
        heading: 'Tips for keeping it going',
        list: [
          'Keep each entry to one idea. Short entries are easier to reread.',
          'Always say why it matters. A quote with no note can feel flat a month later.',
          'Put it in your own words when you can. That is what makes it yours.',
          'Pin the few you want to see every day. See [Pin and archive thoughts](/help/pin-and-archive).',
          'If an entry has done its job, archive it. It stops coming back, but you can still find it.',
          'Make a backup now and then. See [Back up and restore your thoughts](/help/backup-and-restore).',
        ],
      },
      {
        heading: 'The point is the rereading',
        paragraphs: [
          'A commonplace book was never about the notebook. It was about going back to what you wrote until it became part of how you think. Keep it on paper, in a notes app, or in Thought Reps. Just make sure the rereading happens.',
        ],
      },
    ],
  },
];

export const GUIDES_INDEX_PATH = '/guides';

export function guidePath(slug: string): string {
  return `${GUIDES_INDEX_PATH}/${slug}`;
}

export function getGuide(slug: string): Guide | undefined {
  return GUIDES.find((g) => g.slug === slug);
}

/** Drives both the visible breadcrumb and its BreadcrumbList structured data. */
export function getGuideBreadcrumb(
  guide: Guide,
): { name: string; path: string }[] {
  return [
    { name: 'Guides', path: GUIDES_INDEX_PATH },
    { name: guide.title, path: guidePath(guide.slug) },
  ];
}

/** "8 October 2026", fixed to UTC so the prerender doesn't depend on the build machine. */
export function formatGuideDate(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  });
}
