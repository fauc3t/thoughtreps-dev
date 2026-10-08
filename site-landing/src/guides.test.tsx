import { describe, expect, it } from 'vitest';
import { formatGuideDate, GUIDES, guidePath } from './content/guides';
import {
  HELP_ARTICLES,
  HELP_ICONS,
  helpArticlePath,
  parseInline,
} from './content/help';
import {
  getPageMeta,
  GUIDE_ROUTES,
  renderRoute,
  ROUTES,
  sitemapXml,
} from './entry-server';
import { bodyText, gradeLevel } from './readingLevel';

const KNOWN_PATHS = new Set([
  '/',
  '/help',
  '/guides',
  '/privacy',
  '/support',
  ...HELP_ARTICLES.map((a) => helpArticlePath(a.slug)),
  ...GUIDES.map((g) => guidePath(g.slug)),
]);

// Guides are essays for new readers, so they get a little more room than the
// help center's 4.5, but stay plain.
const GUIDE_GRADE_LIMIT = 6;

function allText(): string[] {
  return GUIDES.flatMap((g) => [
    g.title,
    g.description,
    ...g.sections.flatMap((s) => [s.heading ?? '', ...bodyText(s)]),
  ]);
}

describe('guides content', () => {
  it('has unique slugs without dots', () => {
    const slugs = GUIDES.map((g) => g.slug);
    expect(new Set(slugs).size).toBe(slugs.length);
    for (const slug of slugs) expect(slug).toMatch(/^[a-z0-9-]+$/);
  });

  it('points 2 to 4 related help slugs at real articles', () => {
    const help = new Set(HELP_ARTICLES.map((a) => a.slug));
    for (const guide of GUIDES) {
      expect(guide.relatedHelp.length).toBeGreaterThanOrEqual(2);
      expect(guide.relatedHelp.length).toBeLessThanOrEqual(4);
      for (const slug of guide.relatedHelp) {
        expect(help.has(slug), `${guide.slug} -> ${slug}`).toBe(true);
      }
    }
  });

  it('only links inline to real routes and known icons', () => {
    for (const text of allText()) {
      for (const token of parseInline(text)) {
        if (token.kind === 'link') {
          expect(KNOWN_PATHS.has(token.href), token.href).toBe(true);
        }
        expect(token.text).not.toContain('{icon:');
      }
      for (const [, name] of text.matchAll(/\{icon:([^}|]*)/g)) {
        expect(Object.keys(HELP_ICONS)).toContain(name);
      }
    }
  });

  it('keeps titles and descriptions plain text, with no emoji', () => {
    for (const guide of GUIDES) {
      for (const text of [guide.title, guide.description]) {
        expect(text, guide.slug).not.toMatch(/[`{}]|\]\(/);
      }
    }
    for (const text of allText()) {
      expect(text).not.toMatch(/\p{Extended_Pictographic}/u);
    }
  });

  it('uses real ISO dates', () => {
    for (const guide of GUIDES) {
      for (const date of [guide.published, guide.updated ?? guide.published]) {
        expect(date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
        expect(Number.isNaN(Date.parse(date))).toBe(false);
      }
    }
    expect(formatGuideDate('2026-10-08')).toBe('8 October 2026');
  });

  it('keeps every guide at or below the grade limit', () => {
    for (const guide of GUIDES) {
      expect(gradeLevel(guide.sections), guide.slug).toBeLessThanOrEqual(
        GUIDE_GRADE_LIMIT,
      );
    }
  });
});

describe('guide routes', () => {
  it('prerenders the hub and every guide', () => {
    expect(GUIDE_ROUTES.map((r) => r.file)).toEqual([
      'guides/index.html',
      ...GUIDES.map((g) => `guides/${g.slug}/index.html`),
    ]);
    for (const route of GUIDE_ROUTES) {
      expect(route.hydrate).toBe(false);
      expect(ROUTES).toContain(route);
      expect(sitemapXml()).toContain(
        `<loc>https://thoughtreps.com${route.path}</loc>`,
      );
    }
  });

  it('renders each guide with its sections, date and help links', () => {
    for (const guide of GUIDES) {
      const { html } = renderRoute(guidePath(guide.slug));
      expect(html).toContain(guide.sections.find((s) => s.heading)!.heading);
      expect(html).toContain(`dateTime="${guide.published}"`);
      for (const slug of guide.relatedHelp) {
        expect(html).toContain(`href="${helpArticlePath(slug)}"`);
      }
      const figures = guide.sections.filter((s) => s.example).length;
      expect(html.match(/<figure/g)?.length ?? 0).toBe(figures);
    }
  });

  it('lists guides on the hub, the help center and in the footer', () => {
    for (const path of ['/guides', '/help']) {
      const { html } = renderRoute(path);
      for (const guide of GUIDES) {
        expect(html, path).toContain(`href="${guidePath(guide.slug)}"`);
      }
    }
    expect(renderRoute('/').html).toContain('href="/guides"');
  });

  it('gives each guide Article and BreadcrumbList structured data', () => {
    for (const guide of GUIDES) {
      const meta = getPageMeta(guidePath(guide.slug));
      expect(meta.canonical).toBe(
        `https://thoughtreps.com/guides/${guide.slug}`,
      );
      const types = meta.jsonLd.map((d) => (d as { '@type': string })['@type']);
      expect(types).toEqual(['BreadcrumbList', 'Article']);
      const article = meta.jsonLd[1] as Record<string, unknown>;
      expect(article.headline).toBe(guide.title);
      expect(article.datePublished).toBe(guide.published);
    }
  });

  it('serves a noindex 404 for unknown guide paths', () => {
    expect(getPageMeta('/guides/nope').noindex).toBe(true);
  });
});
