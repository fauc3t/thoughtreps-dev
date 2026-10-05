import { renderToString } from 'react-dom/server';
import { LandingPage, NotFoundPage } from './App';

const TITLE = 'Thought Reps: write it down, it comes back';
const DESCRIPTION =
  'Thought Reps is a notebook for iPhone that hands your ideas back to you. Write a thought in five seconds and it returns to your timeline a week later. No account, stays on your phone.';
const CANONICAL = 'https://thoughtreps.com/';

export const ROUTES = [
  { path: '/', file: 'index.html', hydrate: true },
  { path: '/404', file: '404.html', hydrate: false },
] as const;

export function renderRoute(path: string): { html: string; head: string } {
  if (path === '/') {
    return {
      html: renderToString(<LandingPage />),
      head: [
        `<title>${TITLE}</title>`,
        `<meta name="description" content="${DESCRIPTION}" />`,
        `<link rel="canonical" href="${CANONICAL}" />`,
      ].join('\n    '),
    };
  }
  return {
    html: renderToString(<NotFoundPage />),
    head: [
      '<title>Page not found | Thought Reps</title>',
      '<meta name="robots" content="noindex" />',
    ].join('\n    '),
  };
}

const HEAD_MARKER = /<!--ssr-head-->[\s\S]*?<!--\/ssr-head-->/;
const OUTLET_MARKER = '<!--ssr-outlet-->';

/** Fills the built index.html template for one route. Strips client JS from routes that don't hydrate. */
export function buildPage(
  template: string,
  route: { path: string; hydrate: boolean },
): string {
  if (!HEAD_MARKER.test(template) || !template.includes(OUTLET_MARKER)) {
    throw new Error(
      'index.html is missing the ssr-head/ssr-outlet markers. Run `vite build` first; prerender is not re-runnable on its own output.',
    );
  }
  const { html, head } = renderRoute(route.path);
  let page = template
    .replace(HEAD_MARKER, () => head)
    .replace(OUTLET_MARKER, () => html);
  if (!route.hydrate) {
    page = page
      .replace(/<script type="module"[^>]*><\/script>\s*/g, '')
      .replace(/<link rel="modulepreload"[^>]*>\s*/g, '');
  }
  return page;
}
