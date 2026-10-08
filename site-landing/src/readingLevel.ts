// Flesch-Kincaid scoring shared by the help and guides tests, which cap each
// page's reading level.
import { parseInline, type HelpSection } from './content/help';

export function bodyText(section: HelpSection): string[] {
  return [
    ...(section.paragraphs ?? []),
    ...(section.steps ?? []),
    ...(section.list ?? []),
    ...(section.example ? [section.example.caption] : []),
  ];
}

function countSyllables(word: string): number {
  const w = word.toLowerCase().replace(/[^a-z]/g, '');
  if (w.length <= 3) return 1;
  const stem = w
    .replace(/(?:[^laeiouy]es|ed|[^laeiouy]e)$/, '')
    .replace(/^y/, '');
  return Math.max(1, stem.match(/[aeiouy]+/g)?.length ?? 1);
}

/** What a reader reads as prose: icons, `code` and "quoted UI labels" are dropped, link text is kept. */
function proseOf(text: string): string {
  const spoken = parseInline(text)
    .map((t) => (t.kind === 'icon' || t.kind === 'code' ? '' : t.text))
    .join('')
    .replace(/["“][^"”]*["”]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return spoken === '' || /[.!?:]$/.test(spoken) ? spoken : `${spoken}.`;
}

/** Flesch-Kincaid grade level with a naive syllable count. */
export function gradeLevel(sections: HelpSection[]): number {
  const text = sections.flatMap(bodyText).map(proseOf).join(' ');
  const sentences = text.split(/[.!?:]+(?:\s|$)/).filter((s) => /\w/.test(s));
  const words = text.match(/[A-Za-z0-9][A-Za-z0-9'’-]*/g) ?? [];
  const syllables = words.reduce((n, w) => n + countSyllables(w), 0);
  return (
    0.39 * (words.length / sentences.length) +
    11.8 * (syllables / words.length) -
    15.59
  );
}
