import { renderToString } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { LandingPage } from './App';
import { HelpExampleView } from './components/HelpExamples';
import { InlineIcon } from './components/HelpIcons';
import {
  getFaqEntries,
  getHelpBreadcrumb,
  HELP_ARTICLES,
  HELP_CATEGORIES,
  HELP_EXAMPLE_KINDS,
  HELP_ICONS,
  helpArticlePath,
  parseInline,
  toPlainText,
  type HelpArticle,
  type HelpSection,
} from './content/help';
import {
  buildPage,
  getPageMeta,
  HELP_ROUTES,
  renderHead,
  renderRoute,
  robotsTxt,
  ROUTES,
  sitemapXml,
} from './entry-server';

const TEMPLATE = `<html><head><!--ssr-head--><title>x</title><!--/ssr-head-->
<script type="module" crossorigin src="/assets/a.js"></script>
<link rel="modulepreload" href="/assets/b.js">
<link rel="stylesheet" href="/assets/a.css"></head><body><div id="root"><!--ssr-outlet--></div></body></html>`;

const KNOWN_PATHS = new Set([
  '/',
  '/help',
  ...HELP_ARTICLES.map((a) => helpArticlePath(a.slug)),
]);

const FAQ = HELP_ARTICLES.find((a) => a.faq)!;
const BACKUP = HELP_ARTICLES.find((a) => a.slug === 'backup-and-restore')!;

function allText(): string[] {
  return [
    ...HELP_CATEGORIES.flatMap((c) => [c.title, c.description]),
    ...HELP_ARTICLES.flatMap((a) => [
      a.title,
      a.description,
      ...a.sections.flatMap((s) => [s.heading ?? '', ...bodyText(s)]),
    ]),
  ];
}

function bodyText(section: HelpSection): string[] {
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
function gradeLevel(article: HelpArticle): number {
  const text = article.sections.flatMap(bodyText).map(proseOf).join(' ');
  const sentences = text.split(/[.!?:]+(?:\s|$)/).filter((s) => /\w/.test(s));
  const words = text.match(/[A-Za-z0-9][A-Za-z0-9'’-]*/g) ?? [];
  const syllables = words.reduce((n, w) => n + countSyllables(w), 0);
  return (
    0.39 * (words.length / sentences.length) +
    11.8 * (syllables / words.length) -
    15.59
  );
}

describe('help content', () => {
  it('has unique article slugs', () => {
    const slugs = HELP_ARTICLES.map((a) => a.slug);
    expect(new Set(slugs).size).toBe(slugs.length);
  });

  it('puts every article in a real category, and every category has articles', () => {
    for (const article of HELP_ARTICLES) {
      expect(
        HELP_CATEGORIES.some((c) => c.slug === article.category),
        article.slug,
      ).toBe(true);
    }
    for (const category of HELP_CATEGORIES) {
      expect(
        HELP_ARTICLES.some((a) => a.category === category.slug),
        category.slug,
      ).toBe(true);
    }
  });

  it('resolves every related-article slug to another article, 2 to 4 each', () => {
    const slugs = new Set(HELP_ARTICLES.map((a) => a.slug));
    for (const article of HELP_ARTICLES) {
      expect(article.related.length, article.slug).toBeGreaterThanOrEqual(2);
      expect(article.related.length, article.slug).toBeLessThanOrEqual(4);
      expect(new Set(article.related).size, article.slug).toBe(
        article.related.length,
      );
      for (const slug of article.related) {
        expect(slugs.has(slug), `${article.slug} -> ${slug}`).toBe(true);
        expect(slug).not.toBe(article.slug);
      }
    }
  });

  it('only links inline to real routes', () => {
    for (const text of allText()) {
      for (const token of parseInline(text)) {
        if (token.kind === 'link') {
          expect(KNOWN_PATHS.has(token.href), token.href).toBe(true);
        }
      }
    }
  });

  it('keeps FAQ sections to a question and an answer', () => {
    for (const section of FAQ.sections) {
      expect(section.heading).toBeTruthy();
      expect(section.paragraphs?.length).toBeGreaterThan(0);
      expect(section.list).toBeUndefined();
      expect(section.steps).toBeUndefined();
      expect(section.example).toBeUndefined();
    }
  });

  it('contains no emoji', () => {
    for (const text of allText()) {
      expect(text).not.toMatch(/\p{Extended_Pictographic}/u);
    }
  });

  it('keeps titles and descriptions plain text', () => {
    for (const article of HELP_ARTICLES) {
      for (const text of [article.title, article.description]) {
        expect(text, article.slug).not.toMatch(/[`{}]|\]\(/);
      }
    }
  });
});

// The rewrite scores 1.8 to 3.9 on this measure (the old copy reached 4.7), so
// 4.5 leaves a little room for edits and fails if articles drift back up.
const GRADE_LIMIT = 4.5;

describe('reading level', () => {
  it('keeps every article at or below the grade limit', () => {
    for (const article of HELP_ARTICLES) {
      expect(gradeLevel(article), article.slug).toBeLessThanOrEqual(
        GRADE_LIMIT,
      );
    }
  });

  it('estimates grade the way the limit assumes', () => {
    const simple = { sections: [{ paragraphs: ['The cat sat on the mat.'] }] };
    const dense = {
      sections: [
        {
          paragraphs: [
            'Notwithstanding considerable organizational complexity, comprehensive documentation facilitates institutional understanding.',
          ],
        },
      ],
    };
    expect(gradeLevel(simple as HelpArticle)).toBeLessThan(2);
    expect(gradeLevel(dense as HelpArticle)).toBeGreaterThan(GRADE_LIMIT + 5);
  });
});

describe('help icons', () => {
  const RAW_TOKEN = /\{icon:([^}|]*)(?:\|decorative)?\}/g;

  it('resolves every icon token used in the content', () => {
    for (const text of allText()) {
      for (const [, name] of text.matchAll(RAW_TOKEN)) {
        expect(Object.keys(HELP_ICONS), `{icon:${name}}`).toContain(name);
      }
      for (const token of parseInline(text)) {
        expect(token.text).not.toContain('{icon:');
      }
    }
  });

  it('leaves an unknown icon name as visible text so it cannot slip through', () => {
    expect(parseInline('tap {icon:nope}')).toEqual([
      { kind: 'text', text: 'tap ' },
      { kind: 'text', text: '{icon:nope}' },
    ]);
  });

  it('turns tokens into words for plain text', () => {
    expect(toPlainText('Tap {icon:search} or {icon:settings}.')).toBe(
      'Tap Search or Settings.',
    );
  });

  it('draws every icon as a labelled image', () => {
    for (const [name, label] of Object.entries(HELP_ICONS)) {
      const html = renderToString(
        <InlineIcon name={name as keyof typeof HELP_ICONS} />,
      );
      expect(html, name).toContain('role="img"');
      expect(html, name).toContain(`aria-label="${label}"`);
      expect(html, name).toMatch(/<svg[^>]*aria-hidden="true"/);
    }
  });

  it('hides decorative chips from assistive tech and plain text', () => {
    const html = renderToString(<InlineIcon name="archive" decorative />);
    expect(html).toContain('aria-hidden="true"');
    expect(html).not.toContain('role="img"');
    expect(html).not.toContain('aria-label');
    expect(toPlainText('tap {icon:archive|decorative} "Archive".')).toBe(
      'tap  "Archive".',
    );
  });

  it('only marks a chip decorative when a quoted label follows it', () => {
    let seen = 0;
    for (const text of allText()) {
      const marked = text.match(/\{icon:[a-z-]+\|decorative\}/g) ?? [];
      const labelled =
        text.match(/\{icon:[a-z-]+\|decorative\} "[^"]+"/g) ?? [];
      expect(labelled, text).toHaveLength(marked.length);
      seen += marked.length;
    }
    expect(seen).toBeGreaterThan(0);
  });

  it('uses icons in the article pages', () => {
    const { html } = renderRoute(helpArticlePath('the-timeline'));
    expect(html).toContain('aria-label="Search"');
    expect(html).toContain('aria-label="Settings"');
    expect(html).not.toContain('{icon:');
  });
});

describe('help examples', () => {
  const used = HELP_ARTICLES.flatMap((a) =>
    a.sections.flatMap((s) => (s.example ? [s.example] : [])),
  );

  it('renders every example kind inside a figure with a caption', () => {
    for (const kind of HELP_EXAMPLE_KINDS) {
      const html = renderToString(
        <HelpExampleView example={{ kind, caption: 'A caption.' }} />,
      );
      const doc = new DOMParser().parseFromString(html, 'text/html');
      expect(doc.querySelector('figure figcaption')?.textContent, kind).toBe(
        'A caption.',
      );
      const focusable = doc.querySelectorAll('input, button, a, [tabindex]');
      if (kind === 'blurred-block') {
        const checkbox = doc.querySelector('input[type="checkbox"]');
        expect(checkbox, kind).not.toBeNull();
        expect(checkbox!.closest('[aria-hidden="true"]'), kind).toBeNull();
        expect(checkbox!.getAttribute('aria-label'), kind).toBeTruthy();
      } else {
        expect(
          doc.querySelector('figure > div')?.getAttribute('aria-hidden'),
          kind,
        ).toBe('true');
        expect(focusable.length, kind).toBe(0);
      }
    }
  });

  it('uses every kind at least once, with a caption', () => {
    expect(new Set(used.map((e) => e.kind))).toEqual(
      new Set(HELP_EXAMPLE_KINDS),
    );
    for (const example of used) {
      expect(example.caption.length, example.kind).toBeGreaterThan(10);
    }
  });

  it('gives every article an example except the text-only ones', () => {
    const textOnly = new Set(['privacy', 'send-feedback', 'faq']);
    for (const article of HELP_ARTICLES) {
      const count = article.sections.filter((s) => s.example).length;
      if (textOnly.has(article.slug)) {
        expect(count, article.slug).toBe(0);
      } else {
        expect(count, article.slug).toBeGreaterThanOrEqual(1);
      }
    }
  });

  it('shows the examples on the article pages', () => {
    for (const article of HELP_ARTICLES) {
      const { html } = renderRoute(helpArticlePath(article.slug));
      const expected = article.sections.filter((s) => s.example).length;
      expect(html.match(/<figure/g)?.length ?? 0, article.slug).toBe(expected);
    }
  });
});

describe('help routes', () => {
  it('prerenders the hub and every article to <path>/index.html', () => {
    expect(HELP_ROUTES.map((r) => r.file)).toEqual([
      'help/index.html',
      ...HELP_ARTICLES.map((a) => `help/${a.slug}/index.html`),
    ]);
    for (const route of HELP_ROUTES) {
      expect(route.hydrate).toBe(false);
      expect(ROUTES).toContain(route);
    }
  });

  it('keeps the landing page and 404 routes', () => {
    expect(ROUTES.find((r) => r.path === '/')).toMatchObject({
      file: 'index.html',
      hydrate: true,
    });
    expect(ROUTES.find((r) => r.path === '/404')).toMatchObject({
      file: '404.html',
      hydrate: false,
    });
  });

  it('enforces title and description lengths on every indexable route', () => {
    for (const route of ROUTES.filter((r) => !r.noindex)) {
      const meta = getPageMeta(route.path);
      expect(meta.title.length, `${route.path} title`).toBeLessThanOrEqual(70);
      expect(meta.description, `${route.path} description`).toBeTruthy();
      expect(
        meta.description!.length,
        `${route.path} description`,
      ).toBeLessThanOrEqual(160);
      expect(meta.description!.length).toBeGreaterThan(50);
    }
  });

  it('gives every indexable route a distinct title and description', () => {
    const routes = ROUTES.filter((r) => !r.noindex).map((r) =>
      getPageMeta(r.path),
    );
    expect(new Set(routes.map((m) => m.title)).size).toBe(routes.length);
    expect(new Set(routes.map((m) => m.description)).size).toBe(routes.length);
  });

  it('uses canonical URLs without a trailing slash', () => {
    expect(getPageMeta('/help').canonical).toBe('https://thoughtreps.com/help');
    expect(getPageMeta('/help/backup-and-restore').canonical).toBe(
      'https://thoughtreps.com/help/backup-and-restore',
    );
    for (const route of HELP_ROUTES) {
      const canonical = getPageMeta(route.path).canonical!;
      expect(canonical.endsWith('/')).toBe(false);
      expect(renderRoute(route.path).head).toContain(
        `<link rel="canonical" href="${canonical}" />`,
      );
    }
  });

  it('serves a noindex 404 for unknown help paths', () => {
    expect(getPageMeta('/help/nope').noindex).toBe(true);
  });

  it('strips client JS from help pages', () => {
    const page = buildPage(TEMPLATE, { path: '/help', hydrate: false });
    expect(page).not.toContain('<script type="module"');
    expect(page).not.toContain('modulepreload');
    expect(page).toContain('/assets/a.css');
    expect(page).not.toContain('<!--ssr-');
  });
});

describe('sitemap and robots', () => {
  const sitemap = sitemapXml();

  it('lists every help route and the landing page', () => {
    expect(sitemap).toContain('<loc>https://thoughtreps.com/</loc>');
    expect(sitemap).toContain('<loc>https://thoughtreps.com/help</loc>');
    for (const article of HELP_ARTICLES) {
      expect(sitemap).toContain(
        `<loc>https://thoughtreps.com/help/${article.slug}</loc>`,
      );
    }
    for (const route of HELP_ROUTES) {
      expect(sitemap).toContain(
        `<loc>https://thoughtreps.com${route.path}</loc>`,
      );
    }
  });

  it('has no raw icon tokens', () => {
    expect(sitemap).not.toContain('{icon:');
  });

  it('leaves out the 404', () => {
    expect(sitemap).not.toContain('404');
  });

  it('points robots.txt at the sitemap', () => {
    expect(robotsTxt()).toContain(
      'Sitemap: https://thoughtreps.com/sitemap.xml',
    );
    expect(robotsTxt()).toContain('Allow: /');
  });
});

describe('structured data', () => {
  function jsonLd(path: string): Record<string, unknown>[] {
    return [
      ...renderRoute(path).head.matchAll(
        /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g,
      ),
    ].map((m) => JSON.parse(m[1]));
  }

  it('builds the BreadcrumbList from the same data as the visible breadcrumb', () => {
    const path = helpArticlePath(BACKUP.slug);
    const list = jsonLd(path).find((d) => d['@type'] === 'BreadcrumbList');
    const crumbs = getHelpBreadcrumb(BACKUP);
    expect(list).toEqual({
      '@context': 'https://schema.org',
      '@type': 'BreadcrumbList',
      itemListElement: crumbs.map((c, i) => ({
        '@type': 'ListItem',
        position: i + 1,
        name: c.name,
        item: `https://thoughtreps.com${c.path}`,
      })),
    });

    const html = renderRoute(path).html;
    expect(html).toContain('aria-label="Breadcrumb"');
    expect(html).toContain(
      '<a class="no-underline hover:text-ink hover:underline" href="/help">Help</a>',
    );
    expect(html).toContain(`aria-current="page"`);
    expect(html).toContain(`>${BACKUP.title}</span>`);
  });

  it('adds FAQPage data only to the FAQ article, built from its rendered questions', () => {
    const faq = jsonLd(helpArticlePath(FAQ.slug)).find(
      (d) => d['@type'] === 'FAQPage',
    );
    const entries = getFaqEntries(FAQ);
    expect(entries.length).toBeGreaterThan(5);
    expect(faq).toEqual({
      '@context': 'https://schema.org',
      '@type': 'FAQPage',
      mainEntity: entries.map((e) => ({
        '@type': 'Question',
        name: e.question,
        acceptedAnswer: { '@type': 'Answer', text: e.answer },
      })),
    });
    const html = renderRoute(helpArticlePath(FAQ.slug)).html;
    for (const entry of entries) {
      expect(html).toContain(entry.question);
      expect(entry.answer).not.toMatch(/\]\(|`/);
    }
    for (const article of HELP_ARTICLES.filter((a) => a !== FAQ)) {
      expect(
        jsonLd(helpArticlePath(article.slug)).some(
          (d) => d['@type'] === 'FAQPage',
        ),
        article.slug,
      ).toBe(false);
    }
  });

  it('writes icon tokens as words in the head and JSON-LD, never raw', () => {
    for (const route of HELP_ROUTES) {
      const { head, html } = renderRoute(route.path);
      expect(head, route.path).not.toContain('{icon:');
      expect(html, route.path).not.toContain('{icon:');
    }
    const faq = renderRoute(helpArticlePath(FAQ.slug)).head;
    expect(faq).toContain('Tap Search on the Timeline');
    for (const entry of getFaqEntries(FAQ)) {
      expect(entry.answer).not.toContain('{');
    }
  });

  it('escapes hostile page metadata in the head', () => {
    const hostile = '</script><img onerror=x> "quoted" & <b>';
    const head = renderHead({
      title: hostile,
      description: hostile,
      canonical: `https://thoughtreps.com/"><script>x</script>`,
      jsonLd: [{ name: hostile }],
    });
    const ld = head.match(
      /<script type="application\/ld\+json">([\s\S]*?)<\/script>/,
    )!;
    expect(ld[1]).not.toMatch(/<\/script/i);
    expect(ld[1]).not.toContain('<');
    expect(JSON.parse(ld[1])).toEqual({ name: hostile });

    const outside = head.replace(ld[0], '');
    expect(outside).not.toContain('<img');
    expect(outside).not.toContain('<b>');
    expect(outside).not.toContain('<script>x');
    expect(outside).toContain(
      '<title>&lt;/script&gt;&lt;img onerror=x&gt; &quot;quoted&quot; &amp; &lt;b&gt;</title>',
    );
    expect(outside).toContain(
      'content="&lt;/script&gt;&lt;img onerror=x&gt; &quot;quoted&quot; &amp; &lt;b&gt;"',
    );
    expect(outside).toContain(
      'href="https://thoughtreps.com/&quot;&gt;&lt;script&gt;x&lt;/script&gt;"',
    );
  });
});

describe('help pages', () => {
  it('links every article from the hub', () => {
    const { html } = renderRoute('/help');
    for (const article of HELP_ARTICLES) {
      expect(html).toContain(`href="${helpArticlePath(article.slug)}"`);
    }
    for (const category of HELP_CATEGORIES) {
      expect(html).toContain(category.title);
    }
    expect(html.match(/<h1/g)).toHaveLength(1);
  });

  it('renders each article with one h1, related links, a back link and a CTA', () => {
    for (const article of HELP_ARTICLES) {
      const { html } = renderRoute(helpArticlePath(article.slug));
      expect(html.match(/<h1/g), article.slug).toHaveLength(1);
      expect(html).toContain('Related articles');
      for (const slug of article.related) {
        expect(html).toContain(`href="${helpArticlePath(slug)}"`);
      }
      expect(html).toContain('href="/help"');
      expect(html).toContain('Back to Help center');
      expect(html).toContain('Coming soon to the');
    }
  });

  it('uses the landing header and footer, with Learn marked current', () => {
    const { html } = renderRoute('/help');
    expect(html).toContain('href="/#how"');
    expect(html).toContain('href="/#get"');
    expect(html).toMatch(/aria-current="page"[^>]*>Learn</);
    expect(html).toContain('aria-label="Footer"');
  });
});

describe('landing links to the help center', () => {
  const html = renderToString(<LandingPage />);

  it('has a Learn link in the header and the footer', () => {
    const links = html.match(/<a[^>]*href="\/help"[^>]*>Learn<\/a>/g) ?? [];
    expect(links).toHaveLength(2);
    expect(html).not.toMatch(/aria-current="page"[^>]*>Learn</);
  });
});
