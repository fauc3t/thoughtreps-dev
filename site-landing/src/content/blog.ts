// Source of truth for /blog: essays on the ideas behind Thought Reps, written
// for people who haven't heard of the app yet (help.ts is for people using
// it). The hub, routes, sitemap, structured data and link-preview cards are
// generated from POSTS, so adding a post is one edit here.
//
// Posts share the help center's section format and inline syntax (`code`,
// [links](/help/slug), {icon:name}). They're content first: mention the app
// lightly, and only for what the shipped app does. Check historical claims
// before publishing.

import type { HelpSection } from './help';

export interface BlogPost {
  slug: string;
  /** Page heading and the start of the <title>; keep it short enough for the suffix. */
  title: string;
  /** Meta description and the lede under the heading. Plain text only. */
  description: string;
  /** ISO date, shown on the page and in the BlogPosting structured data. */
  published: string;
  /** ISO date of the last real content change, if any. */
  updated?: string;
  sections: HelpSection[];
}

export const POSTS: BlogPost[] = [
  {
    slug: 'commonplace-book',
    title: 'What is a commonplace book? A history and how-to',
    description:
      'What a commonplace book is, where it came from, who kept one, from Erasmus and Locke to Jefferson and Octavia Butler, and how to keep one today.',
    published: '2026-10-08',
    sections: [
      {
        paragraphs: [
          'Somewhere in your past is a line you once loved and can no longer find. A sentence from a book. Something a teacher said. An idea you had at 2 a.m. You meant to keep it, and now it is gone.',
          'For a very long time, careful readers have had a fix for this. They kept a commonplace book.',
        ],
      },
      {
        heading: 'What a commonplace book is',
        paragraphs: [
          'A commonplace book is a notebook of things worth keeping: quotes, passages, facts, lessons and your own ideas. It is not a diary. A diary is sorted by date and tells the story of your days. A commonplace book is sorted by idea, and it holds whatever you want to think with later.',
          'The good ones mix other people’s words with your own. A keeper copies a line, then adds a sentence on why it matters. Years later, those small notes are often worth more than the quotes.',
        ],
      },
      {
        heading: 'Bees, flowers and stock themes',
        paragraphs: [
          'The idea is older than the name. In the first century, the Roman writer Seneca told a friend to read like a bee. A bee visits many flowers, he wrote, then turns what it gathers into honey of its own. Read widely, keep what is good, and make it yours.',
          'The name comes from the Latin "locus communis", a "common place". In old schools of public speaking, that meant a stock theme a speaker could draw on, like friendship, luck or death. Students gathered good lines under each theme, so they always had something to say.',
          'Monks in the Middle Ages kept the habit alive. They copied the best lines of the Bible and the old writers into books they called "florilegia", which means a gathering of flowers. Seneca’s bees were still at work.',
        ],
      },
      {
        heading: 'The notebook every student kept',
        paragraphs: [
          'In 1512 the Dutch scholar Erasmus put out a textbook called "De Copia". In it, he told students to make a notebook with headings, like virtues and vices, and to copy the best things they read under the right one. It became one of the most printed school books of its time.',
          'As that kind of schooling spread across Europe, so did the notebook. For a couple of hundred years, keeping a commonplace book was simply part of learning to read well.',
          'In 1686 the English thinker John Locke shared his own method, first in French and then, in 1706, in English. Its big idea was a clever index, so any entry could be found in a few seconds. After that, printers even sold blank commonplace books, ready to fill.',
        ],
      },
      {
        heading: 'Who kept one',
        paragraphs: [
          'Once you start looking, they turn up everywhere. A few of the people who kept one:',
        ],
        list: [
          'Francis Bacon, the English thinker, who filled a notebook with sayings and turns of phrase to use in his writing.',
          'John Milton, the poet of "Paradise Lost". His commonplace book is now in the British Library.',
          'Thomas Jefferson, who copied poets and thinkers into one as a young man. It is one of the few papers left from his early years, and it has been published as a book.',
          'Ralph Waldo Emerson and Henry David Thoreau, who both kept them for years.',
          'Mark Twain, whose notes were closer to a scrapbook. He even patented a scrapbook with glue already on the pages.',
          'Virginia Woolf, who kept reading notebooks full of passages and her own thoughts on them.',
          'Octavia E. Butler, the science fiction writer. Her commonplace books, full of notes for her novels, research and daily life, are kept at the Huntington Library in California.',
        ],
      },
      {
        paragraphs: [
          'Today, writers like Ryan Holiday write about their own versions, and a whole corner of the internet is busy with note-taking systems that are, under the hood, commonplace books.',
        ],
      },
      {
        heading: 'The part everyone skips',
        paragraphs: [
          'The old method had two halves. Copying things down was one. Going back to them was the other. Keepers read their books again and again, and Locke’s index existed so they could find things fast.',
          'That second half is where the value is. An idea you meet once is easy to lose. An idea you meet five times starts to become part of how you think. That is what Seneca meant by honey.',
        ],
      },
      {
        heading: 'Why going digital made it harder',
        paragraphs: [
          'Saving things has never been easier. Highlights, screenshots, bookmarks, a notes app with two thousand notes. But saving got so easy that we save everything and reread almost nothing. Search only helps when you remember what to look for. The ideas you forgot you had are the ones that never come back.',
        ],
      },
      {
        heading: 'How to keep one that works',
        list: [
          'Write one idea per entry. Short entries are easier to find and to reread.',
          'Say where it came from: the book, the person, the day.',
          'Always add a line of your own. Why did this stick? Where might you use it?',
          'Use a few broad headings or tags, like `#quotes`, `#work` or `#health`. Don’t build a filing system you won’t keep up.',
          'Put the rereading on a schedule. Once a week is plenty. The schedule matters more than the tool.',
          'Let entries retire. When an idea has become part of you, stop rereading it.',
        ],
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
        heading: 'Paper or phone?',
        paragraphs: [
          'Paper is lovely, and nothing beats copying a line out by hand. But a notebook can’t remind you to open it. A phone can.',
          'That is the idea behind Thought Reps, the iPhone notebook we make. You write an entry, and a week later it comes back to you on its own. Read it, and it waits another week. Tags are your headings and search is your index, and it all stays on your phone. [See how it works](/help/what-is-thought-reps).',
          'Whatever you use, the lesson of all those notebooks is the same. Writing it down is only half of it. The other half is coming back.',
        ],
      },
    ],
  },
];

export const BLOG_INDEX_PATH = '/blog';

export function blogPostPath(slug: string): string {
  return `${BLOG_INDEX_PATH}/${slug}`;
}

export function getBlogPost(slug: string): BlogPost | undefined {
  return POSTS.find((p) => p.slug === slug);
}

/** Drives both the visible breadcrumb and its BreadcrumbList structured data. */
export function getBlogBreadcrumb(
  post: BlogPost,
): { name: string; path: string }[] {
  return [
    { name: 'Blog', path: BLOG_INDEX_PATH },
    { name: post.title, path: blogPostPath(post.slug) },
  ];
}

/** "8 October 2026", fixed to UTC so the prerender doesn't depend on the build machine. */
export function formatPostDate(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
    timeZone: 'UTC',
  });
}
