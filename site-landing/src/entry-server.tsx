import { renderToString } from 'react-dom/server';
import {
  HelpArticlePage,
  HelpIndexPage,
  LandingPage,
  NotFoundPage,
  PrivacyPolicyPage,
} from './App';
import {
  getFaqEntries,
  getHelpArticle,
  getHelpBreadcrumb,
  HELP_ARTICLES,
  HELP_INDEX_PATH,
  helpArticlePath,
  type HelpArticle,
} from './content/help';

import {
  PRIVACY_DESCRIPTION,
  PRIVACY_PATH,
  PRIVACY_TITLE,
} from './content/privacy';

export const SITE_URL = 'https://thoughtreps.com';

const TITLE = 'Thought Reps: write it down, it comes back';
const DESCRIPTION =
  'A notebook for iPhone that hands your ideas back to you. Write a thought in five seconds and it returns a week later. No account, stays on your phone.';
const HELP_TITLE = 'Help center | Thought Reps';
const HELP_DESCRIPTION =
  'Guides for Thought Reps, the iPhone notebook that brings your ideas back. Learn to write, resurface, review, back up and move your thoughts.';
const HELP_ARTICLE_TITLE_SUFFIX = ' | Thought Reps Help';
const NOT_FOUND_TITLE = 'Page not found | Thought Reps';

export interface Route {
  path: string;
  file: string;
  hydrate: boolean;
  noindex?: boolean;
}

export const HELP_ROUTES: Route[] = [
  { path: HELP_INDEX_PATH, file: 'help/index.html', hydrate: false },
  ...HELP_ARTICLES.map((article) => ({
    path: helpArticlePath(article.slug),
    file: `help/${article.slug}/index.html`,
    hydrate: false,
  })),
];

export const ROUTES: Route[] = [
  { path: '/', file: 'index.html', hydrate: true },
  ...HELP_ROUTES,
  { path: PRIVACY_PATH, file: 'privacy/index.html', hydrate: false },
  { path: '/404', file: '404.html', hydrate: false, noindex: true },
];

export interface PageMeta {
  title: string;
  description?: string;
  canonical?: string;
  noindex?: boolean;
  jsonLd: object[];
}

export function breadcrumbJsonLd(article: HelpArticle): object {
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: getHelpBreadcrumb(article).map((item, i) => ({
      '@type': 'ListItem',
      position: i + 1,
      name: item.name,
      item: SITE_URL + item.path,
    })),
  };
}

export function faqJsonLd(article: HelpArticle): object {
  return {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: getFaqEntries(article).map((entry) => ({
      '@type': 'Question',
      name: entry.question,
      acceptedAnswer: { '@type': 'Answer', text: entry.answer },
    })),
  };
}

function helpArticleFor(path: string): HelpArticle | undefined {
  const prefix = `${HELP_INDEX_PATH}/`;
  return path.startsWith(prefix)
    ? getHelpArticle(path.slice(prefix.length))
    : undefined;
}

export function getPageMeta(path: string): PageMeta {
  if (path === '/') {
    return {
      title: TITLE,
      description: DESCRIPTION,
      canonical: `${SITE_URL}/`,
      jsonLd: [],
    };
  }
  if (path === PRIVACY_PATH) {
    return {
      title: PRIVACY_TITLE,
      description: PRIVACY_DESCRIPTION,
      canonical: SITE_URL + PRIVACY_PATH,
      jsonLd: [],
    };
  }
  if (path === HELP_INDEX_PATH) {
    return {
      title: HELP_TITLE,
      description: HELP_DESCRIPTION,
      canonical: SITE_URL + HELP_INDEX_PATH,
      jsonLd: [],
    };
  }
  const article = helpArticleFor(path);
  if (article) {
    return {
      title: article.title + HELP_ARTICLE_TITLE_SUFFIX,
      description: article.description,
      canonical: SITE_URL + helpArticlePath(article.slug),
      jsonLd: [
        breadcrumbJsonLd(article),
        ...(article.faq ? [faqJsonLd(article)] : []),
      ],
    };
  }
  return { title: NOT_FOUND_TITLE, noindex: true, jsonLd: [] };
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

export function renderHead(meta: PageMeta): string {
  const tags = [`<title>${escapeHtml(meta.title)}</title>`];
  if (meta.description) {
    tags.push(
      `<meta name="description" content="${escapeHtml(meta.description)}" />`,
    );
  }
  if (meta.canonical) {
    tags.push(`<link rel="canonical" href="${escapeHtml(meta.canonical)}" />`);
  }
  if (meta.noindex) tags.push('<meta name="robots" content="noindex" />');
  for (const data of meta.jsonLd) {
    tags.push(
      `<script type="application/ld+json">${JSON.stringify(data).replace(/</g, '\\u003c')}</script>`,
    );
  }
  return tags.join('\n    ');
}

function renderPage(path: string): string {
  if (path === '/') return renderToString(<LandingPage />);
  if (path === PRIVACY_PATH) return renderToString(<PrivacyPolicyPage />);
  if (path === HELP_INDEX_PATH) return renderToString(<HelpIndexPage />);
  const article = helpArticleFor(path);
  if (article) return renderToString(<HelpArticlePage article={article} />);
  return renderToString(<NotFoundPage />);
}

export function renderRoute(path: string): { html: string; head: string } {
  return { html: renderPage(path), head: renderHead(getPageMeta(path)) };
}

export function sitemapXml(routes: readonly Route[] = ROUTES): string {
  const urls = routes
    .filter((route) => !route.noindex)
    .map((route) => {
      const loc = route.path === '/' ? `${SITE_URL}/` : SITE_URL + route.path;
      return `  <url><loc>${escapeHtml(loc)}</loc></url>`;
    })
    .join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls}
</urlset>
`;
}

export function robotsTxt(): string {
  return `User-agent: *
Allow: /

Sitemap: ${SITE_URL}/sitemap.xml
`;
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
