import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
} from '@testing-library/react';
import { renderToString } from 'react-dom/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { LandingPage, NotFoundPage } from './App';
import { setWaitlistJoined } from './waitlistStore';
import { buildPage, renderRoute, ROUTES } from './entry-server';

const TEMPLATE = `<html><head><!--ssr-head--><title>x</title><!--/ssr-head-->
<script type="module" crossorigin src="/assets/a.js"></script>
<link rel="modulepreload" href="/assets/b.js">
<link rel="stylesheet" href="/assets/a.css"></head><body><div id="root"><!--ssr-outlet--></div></body></html>`;

describe('buildPage', () => {
  it('replaces the markers and keeps client JS on hydrated routes', () => {
    const page = buildPage(TEMPLATE, { path: '/', hydrate: true });
    expect(page).not.toContain('<!--ssr-');
    expect(page).toContain('rel="canonical"');
    expect(page).toContain('Write it once');
    expect(page).toContain('<script type="module"');
  });

  it('strips client JS but keeps CSS on the 404', () => {
    const page = buildPage(TEMPLATE, { path: '/404', hydrate: false });
    expect(page).not.toContain('<script');
    expect(page).not.toContain('modulepreload');
    expect(page).toContain('/assets/a.css');
    expect(page).toContain('noindex');
  });

  it('errors clearly when run on an already-prerendered page', () => {
    const page = buildPage(TEMPLATE, { path: '/', hydrate: true });
    expect(() => buildPage(page, { path: '/', hydrate: true })).toThrow(
      /markers/,
    );
  });
});

describe('interactions', () => {
  beforeEach(() => {
    vi.stubGlobal('matchMedia', () => ({ matches: true }));
  });
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
  });

  it('keeps only the front card exposed after the deck advances', () => {
    const { container } = render(<LandingPage />);
    fireEvent.click(screen.getByText('Bring the next one back'));
    const exposed = [...container.querySelectorAll('.note')].filter(
      (n) => !n.hasAttribute('inert'),
    );
    expect(exposed.map((n) => n.getAttribute('data-pos'))).toEqual(['0']);
  });

  it('swaps the nav button for a joined note once signed up', () => {
    const { container } = render(<LandingPage />);
    const nav = () => container.querySelector('header nav')!.textContent;
    expect(nav()).toContain('Join the waitlist');
    act(() => setWaitlistJoined({ email: 'a@b.co', beta: false }));
    expect(nav()).not.toContain('waitlist');
    expect(nav()).toContain("You're on the list");
    expect(
      container.querySelector('header a[href="#waitlist-email"]'),
    ).toBeNull();
    act(() => setWaitlistJoined(null));
  });

  it('advances the deck', () => {
    const { container } = render(<LandingPage />);
    const pos = () =>
      [...container.querySelectorAll('.note')].map((n) =>
        n.getAttribute('data-pos'),
      );
    expect(pos()).toEqual(['0', '1', '2']);
    fireEvent.click(screen.getByText('Bring the next one back'));
    expect(pos()).toEqual(['2', '0', '1']);
  });

  it('reveals and hides the blurred answer', () => {
    render(<LandingPage />);
    const button = screen.getByRole('button', { name: 'Reveal' });
    expect(button.getAttribute('aria-expanded')).toBe('false');
    fireEvent.click(button);
    expect(button.textContent).toBe('Hide');
    expect(button.getAttribute('aria-expanded')).toBe('true');
  });

  it('switches the interval and shows real dates after mount', () => {
    render(<LandingPage />);
    expect(screen.getByText(/Read today · back on/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: '30 days' }));
    expect(
      screen
        .getByRole('button', { name: '30 days' })
        .getAttribute('aria-pressed'),
    ).toBe('true');
    expect(
      screen
        .getByRole('button', { name: '7 days' })
        .getAttribute('aria-pressed'),
    ).toBe('false');
  });

  it('snoozes and archives', () => {
    render(<LandingPage />);
    fireEvent.click(screen.getByRole('button', { name: 'Snooze 1 day' }));
    expect(screen.getByText(/Snoozed · back on/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Archive' }));
    expect(screen.getByText('Archived · restore it any time')).toBeTruthy();
  });

  it('uses relative wording when prerendered', () => {
    const html = renderToString(<LandingPage />);
    expect(html).toContain('See it again next week.');
  });
});

describe('landing page', () => {
  const html = renderToString(<LandingPage />);

  it('renders the key copy', () => {
    expect(html).toContain('Write it down.');
    expect(html).toContain('It comes');
    expect(html).toContain('Write it once. See it again in a week.');
    expect(html).toContain('Your thoughts stay on your phone.');
    expect(html).toContain('Start with one thought.');
  });

  it('links to the contact address', () => {
    expect(html).toContain('href="mailto:hello@thoughtreps.com"');
  });

  it('shows the App Store line as plain text, not a button, with no placeholder links', () => {
    expect(html).toContain('Coming to the App Store · $6.99 once');
    expect(html).not.toContain('href="#"');
    expect(html).not.toContain('Download on the');
    expect(html).not.toContain('Coming soon');
  });

  it('puts the price and the deletion promise in view in the hero', () => {
    expect(html).toContain(
      '$6.99 once · No subscription · No account · Your email is deleted after launch',
    );
  });

  it('claims only the backup file for export, never Markdown export', () => {
    expect(html).toContain('.thoughtreps file');
    expect(html).not.toContain('one Markdown file per thought');
    expect(html).not.toContain('A .zip of JSON');
  });

  it('argues for rereading and mentions search', () => {
    expect(html).toContain(
      'Most notes apps are where ideas go to be forgotten.',
    );
    expect(html).toContain('commonplace books');
    expect(html).toContain('even archived');
  });

  it('joins the waitlist from the nav and calls help "Help"', () => {
    expect(html).toMatch(
      /href="#waitlist-email"[^>]*>Join<span[^>]*> the<\/span> waitlist/,
    );
    expect(html).not.toContain('Get the app');
    expect(html).not.toMatch(/>Learn</);
  });

  it('hides the back cards of the deck from assistive tech', () => {
    const cards = [...html.matchAll(/<article class="note stk"[^>]*>/g)].map(
      (m) => m[0],
    );
    expect(cards).toHaveLength(3);
    expect(cards.filter((c) => c.includes('aria-hidden="true"'))).toHaveLength(
      2,
    );
    expect(cards.filter((c) => c.includes('inert'))).toHaveLength(2);
  });

  it('computes the footer year at render', () => {
    expect(html).toContain(`© ${new Date().getFullYear()} Thought Reps LLC`);
  });

  it('makes no Google Fonts requests', () => {
    expect(html).not.toContain('fonts.googleapis.com');
    expect(html).not.toContain('fonts.gstatic.com');
  });
});

describe('prerender routes', () => {
  it('renders every route with a title and content', () => {
    for (const route of ROUTES) {
      const { html, head } = renderRoute(route.path);
      expect(head).toContain('<title>');
      expect(html.length).toBeGreaterThan(100);
    }
  });

  it('marks the landing page canonical and the 404 noindex', () => {
    expect(renderRoute('/').head).toContain(
      '<link rel="canonical" href="https://thoughtreps.com/" />',
    );
    expect(renderRoute('/404').head).toContain('noindex');
  });

  it('renders the not-found page', () => {
    expect(renderToString(<NotFoundPage />)).toContain('404');
  });
});

describe('waitlist form placement', () => {
  it('renders in the hero and the final CTA', () => {
    const html = renderToString(<LandingPage />);
    expect(html.match(/Notify me/g)).toHaveLength(2);
    expect(html).toMatch(/id="get"[\s\S]*Notify me/);
  });
});
