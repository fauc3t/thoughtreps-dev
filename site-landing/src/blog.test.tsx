import { describe, expect, it } from 'vitest';
import {
  blogPostPath,
  formatPostDate,
  POSTS,
  readingMinutes,
} from './content/blog';
import {
  HELP_ARTICLES,
  HELP_ICONS,
  helpArticlePath,
  parseInline,
} from './content/help';
import {
  BLOG_ROUTES,
  getPageMeta,
  renderRoute,
  ROUTES,
  sitemapXml,
} from './entry-server';
import { bodyText, gradeLevel } from './readingLevel';

const KNOWN_PATHS = new Set([
  '/',
  '/help',
  '/blog',
  '/privacy',
  '/support',
  ...HELP_ARTICLES.map((a) => helpArticlePath(a.slug)),
  ...POSTS.map((p) => blogPostPath(p.slug)),
]);

// Posts are essays for new readers, so they get more room than the help
// center's 4.5, but stay plain.
const POST_GRADE_LIMIT = 7;

function allText(): string[] {
  return POSTS.flatMap((p) => [
    p.title,
    p.description,
    ...p.sections.flatMap((s) => [s.heading ?? '', ...bodyText(s)]),
  ]);
}

describe('blog content', () => {
  it('has unique slugs without dots', () => {
    const slugs = POSTS.map((p) => p.slug);
    expect(new Set(slugs).size).toBe(slugs.length);
    for (const slug of slugs) expect(slug).toMatch(/^[a-z0-9-]+$/);
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
    for (const post of POSTS) {
      for (const text of [post.title, post.description]) {
        expect(text, post.slug).not.toMatch(/[`{}]|\]\(/);
      }
    }
    for (const text of allText()) {
      expect(text).not.toMatch(/\p{Extended_Pictographic}/u);
    }
  });

  it('uses real ISO dates', () => {
    for (const post of POSTS) {
      for (const date of [post.published, post.updated ?? post.published]) {
        expect(date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
        expect(Number.isNaN(Date.parse(date))).toBe(false);
      }
    }
    expect(formatPostDate('2026-10-08')).toBe('October 8, 2026');
  });

  it('estimates a reading time of at least a minute', () => {
    for (const post of POSTS) {
      expect(readingMinutes(post)).toBeGreaterThanOrEqual(1);
    }
    const short = { ...POSTS[0], sections: [{ paragraphs: ['Hi.'] }] };
    expect(readingMinutes(short)).toBe(1);
  });

  it('keeps every post at or below the grade limit', () => {
    for (const post of POSTS) {
      expect(gradeLevel(post.sections), post.slug).toBeLessThanOrEqual(
        POST_GRADE_LIMIT,
      );
    }
  });
});

describe('blog routes', () => {
  it('prerenders the hub and every post', () => {
    expect(BLOG_ROUTES.map((r) => r.file)).toEqual([
      'blog/index.html',
      ...POSTS.map((p) => `blog/${p.slug}/index.html`),
    ]);
    for (const route of BLOG_ROUTES) {
      expect(route.hydrate).toBe(false);
      expect(ROUTES).toContain(route);
      expect(sitemapXml()).toContain(
        `<loc>https://thoughtreps.com${route.path}</loc>`,
      );
    }
  });

  it('renders each post with its sections and date', () => {
    for (const post of POSTS) {
      const { html } = renderRoute(blogPostPath(post.slug));
      for (const section of post.sections) {
        if (section.heading) expect(html).toContain(section.heading);
      }
      expect(html).toContain(`dateTime="${post.published}"`);
      expect(html).toContain(`${readingMinutes(post)} min read`);
      const figures = post.sections.filter((s) => s.example).length;
      expect(html.match(/<figure/g)?.length ?? 0).toBe(figures);
    }
  });

  it('lists posts on the hub and the help center, and links the blog in the footer', () => {
    for (const path of ['/blog', '/help']) {
      const { html } = renderRoute(path);
      for (const post of POSTS) {
        expect(html, path).toContain(`href="${blogPostPath(post.slug)}"`);
      }
    }
    expect(renderRoute('/').html).toContain('href="/blog"');
  });

  it('gives each post BlogPosting and BreadcrumbList structured data', () => {
    for (const post of POSTS) {
      const meta = getPageMeta(blogPostPath(post.slug));
      expect(meta.canonical).toBe(`https://thoughtreps.com/blog/${post.slug}`);
      const types = meta.jsonLd.map((d) => (d as { '@type': string })['@type']);
      expect(types).toEqual(['BreadcrumbList', 'BlogPosting']);
      const posting = meta.jsonLd[1] as Record<string, unknown>;
      expect(posting.headline).toBe(post.title);
      expect(posting.datePublished).toBe(post.published);
    }
  });

  it('serves a noindex 404 for unknown post paths and the old /guides', () => {
    expect(getPageMeta('/blog/nope').noindex).toBe(true);
    expect(getPageMeta('/guides').noindex).toBe(true);
  });
});
