import { renderToString } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { LandingPage } from './App';
import { getHelpArticle } from './content/help';
import {
  SUPPORT_DESCRIPTION,
  SUPPORT_HELP_SLUGS,
  SUPPORT_TITLE,
} from './content/support';
import { renderRoute, ROUTES, sitemapXml } from './entry-server';

describe('support page', () => {
  it('prerenders at /support with title, canonical and mailto', () => {
    expect(ROUTES).toContainEqual({
      path: '/support',
      file: 'support/index.html',
      hydrate: false,
    });
    const { html, head } = renderRoute('/support');
    expect(head).toContain('<title>Support | Thought Reps</title>');
    expect(head).toContain(
      '<link rel="canonical" href="https://thoughtreps.com/support" />',
    );
    expect(SUPPORT_TITLE.length).toBeLessThanOrEqual(70);
    expect(SUPPORT_DESCRIPTION.length).toBeLessThanOrEqual(160);
    expect(html.match(/<h1/g)).toHaveLength(1);
    expect(html).toContain('href="mailto:hello@thoughtreps.com"');
    expect(html).toContain('Request a Feature');
    expect(html).toContain('Report a Problem');
  });

  it('is in the sitemap', () => {
    expect(sitemapXml()).toContain(
      '<loc>https://thoughtreps.com/support</loc>',
    );
  });

  it('is linked from the footer', () => {
    expect(renderToString(<LandingPage />)).toMatch(
      /<a [^>]*href="\/support"[^>]*>Support<\/a>/,
    );
  });

  it('is linked from the help index and the send-feedback article', () => {
    expect(renderRoute('/help').html).toMatch(
      /<a [^>]*href="\/support"[^>]*>Contact support<\/a>/,
    );
    expect(renderRoute('/help/send-feedback').html).toContain(
      'href="/support"',
    );
  });

  it('links only to help articles that exist', () => {
    const { html } = renderRoute('/support');
    const slugs = [...html.matchAll(/href="\/help\/([^"/]+)"/g)].map(
      (m) => m[1],
    );
    expect(slugs).toHaveLength(SUPPORT_HELP_SLUGS.length);
    for (const slug of slugs) expect(getHelpArticle(slug)).toBeDefined();
    expect(html).toContain('href="/help"');
    expect(html).toContain('href="/privacy"');
  });
});
