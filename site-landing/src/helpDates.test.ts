// @vitest-environment node
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { HELP_ARTICLES, helpArticlePath } from './content/help';
import { HELP_SOURCE_FILE, helpDatesFromBlame } from './content/helpDates';
import { renderRoute } from './entry-server';

/** One `git blame --line-porcelain` entry. */
function entry(content: string, time: number, tz = '+0000'): string {
  return [
    `${'a'.repeat(40)} 1 1 1`,
    'author Someone',
    `author-time ${time}`,
    `author-tz ${tz}`,
    'committer Someone',
    `committer-time ${time}`,
    `committer-tz ${tz}`,
    'summary x',
    'filename src/content/help.ts',
    `\t${content}`,
  ].join('\n');
}

const DAY = 86400;
const OCT_1 = Date.UTC(2026, 9, 1) / 1000;

describe('help dates from git blame', () => {
  it('takes the newest line of each article, and ignores category slugs', () => {
    const blame = [
      entry("    slug: 'writing',", OCT_1 + 30 * DAY),
      entry('export const HELP_ARTICLES: HelpArticle[] = [', OCT_1),
      entry('  {', OCT_1),
      entry("    slug: 'one',", OCT_1),
      entry("    title: 'One',", OCT_1 + 5 * DAY),
      entry('  },', OCT_1),
      entry('  {', OCT_1),
      entry("    slug: 'two',", OCT_1 + 2 * DAY),
      entry('  },', OCT_1),
      entry('];', OCT_1),
      entry("export const HELP_INDEX_PATH = '/help';", OCT_1 + 40 * DAY),
    ].join('\n');
    expect(helpDatesFromBlame(blame, ['one', 'two'])).toEqual({
      one: '2026-10-06',
      two: '2026-10-03',
    });
  });

  it("uses the committer's time zone for the calendar day", () => {
    // 02:00 UTC on Oct 2 is still Oct 1 in New York (-0400).
    const time = OCT_1 + DAY + 2 * 3600;
    const blame = entry("    slug: 'one',", time, '-0400');
    expect(helpDatesFromBlame(blame, ['one'])).toEqual({ one: '2026-10-01' });
    expect(
      helpDatesFromBlame(entry("    slug: 'one',", time), ['one']),
    ).toEqual({ one: '2026-10-02' });
  });

  it('dates every real article from this repo', () => {
    const blame = execFileSync(
      'git',
      ['blame', '--line-porcelain', '--', HELP_SOURCE_FILE],
      {
        cwd: resolve(__dirname, '..'),
        encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
      },
    );
    const dates = helpDatesFromBlame(
      blame,
      HELP_ARTICLES.map((a) => a.slug),
    );
    for (const article of HELP_ARTICLES) {
      expect(dates[article.slug], article.slug).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    }
  });

  it('shows the date on the article page only when prerender has one', () => {
    const path = helpArticlePath('tags');
    expect(
      renderRoute(path, undefined, { help: { tags: '2026-10-08' } }).html,
    ).toContain('Updated <time dateTime="2026-10-08">October 8, 2026</time>');
    expect(renderRoute(path).html).not.toContain('Updated');
  });
});
