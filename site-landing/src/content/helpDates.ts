// Each help article's "Updated" date comes from git, not a hand-kept field:
// prerender runs `git blame --line-porcelain` on help.ts and this picks the
// newest commit among each article's lines. A deleted line leaves no blame,
// so an edit that only removes text doesn't move the date.

export const HELP_SOURCE_FILE = 'src/content/help.ts';

const SLUG_LINE = /^\s*slug: '([a-z0-9-]+)',$/;
const ARTICLES_END = /^export const HELP_INDEX_PATH\b/;

/** Calendar date of a commit in the committer's own time zone, e.g. `-0400`. */
function localDate(epochSeconds: number, tz: string): string {
  const sign = tz.startsWith('-') ? -1 : 1;
  const minutes =
    sign * (Number(tz.slice(1, 3)) * 60 + Number(tz.slice(3, 5)) || 0);
  return new Date((epochSeconds + minutes * 60) * 1000)
    .toISOString()
    .slice(0, 10);
}

/**
 * Maps each article slug to the ISO date of its newest line, from the output
 * of `git blame --line-porcelain` on help.ts. Slugs not found are left out.
 */
export function helpDatesFromBlame(
  porcelain: string,
  slugs: readonly string[],
): Record<string, string> {
  const wanted = new Set(slugs);
  const newest = new Map<string, { time: number; tz: string }>();
  let time = 0;
  let tz = '+0000';
  let current: string | undefined;
  for (const line of porcelain.split('\n')) {
    if (line.startsWith('committer-time ')) {
      time = Number(line.slice('committer-time '.length));
    } else if (line.startsWith('committer-tz ')) {
      tz = line.slice('committer-tz '.length);
    } else if (line.startsWith('\t')) {
      const content = line.slice(1);
      const slug = SLUG_LINE.exec(content)?.[1];
      if (slug && wanted.has(slug)) current = slug;
      else if (ARTICLES_END.test(content)) current = undefined;
      if (current) {
        const best = newest.get(current);
        if (!best || time > best.time) newest.set(current, { time, tz });
      }
    }
  }
  return Object.fromEntries(
    [...newest].map(([slug, { time, tz }]) => [slug, localDate(time, tz)]),
  );
}
