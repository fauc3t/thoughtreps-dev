import { renderToString } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { LandingPage } from './App';
import { renderRoute, ROUTES, sitemapXml } from './entry-server';

describe('privacy policy', () => {
  it('prerenders at /privacy with title, canonical and the update date', () => {
    expect(ROUTES).toContainEqual({
      path: '/privacy',
      file: 'privacy/index.html',
      hydrate: false,
    });
    const { html, head } = renderRoute('/privacy');
    expect(head).toContain('<title>Privacy policy | Thought Reps</title>');
    expect(head).toContain(
      '<link rel="canonical" href="https://thoughtreps.com/privacy" />',
    );
    expect(html).toContain('<h1');
    expect(html).toContain('October 7, 2026');
    expect(html).toContain('href="mailto:hello@thoughtreps.com"');
  });

  it('discloses the launch list', () => {
    const { html } = renderRoute('/privacy');
    expect(html).toContain('launch list');
    expect(html).toContain('Amazon DynamoDB');
    expect(html).toContain('when you joined');
    expect(html).toContain('We get an email notice with your address');
    expect(html).toContain('We delete the list and those notices after launch');
    expect(html).toContain(
      'your thoughts, your feedback or your email address',
    );
  });

  it('is in the sitemap', () => {
    expect(sitemapXml()).toContain(
      '<loc>https://thoughtreps.com/privacy</loc>',
    );
  });

  it('is linked from the footer and the home Privacy section', () => {
    const html = renderToString(<LandingPage />);
    expect(html).toMatch(/<a [^>]*href="\/privacy"[^>]*>Privacy<\/a>/);
    expect(html).toMatch(
      /<a [^>]*href="\/privacy"[^>]*>Read the privacy policy<\/a>/,
    );
  });

  it('is linked from the help privacy article', () => {
    expect(renderRoute('/help/privacy').html).toContain('href="/privacy"');
  });
});
