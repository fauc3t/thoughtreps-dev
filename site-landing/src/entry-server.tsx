import { renderToString } from 'react-dom/server';
import {
  BlogIndexPage,
  BlogPostPage,
  HelpArticlePage,
  HelpIndexPage,
  LandingPage,
  NotFoundPage,
  PrivacyPolicyPage,
  SupportPage,
} from './App';
import { HELP_SOURCE_FILE, helpDatesFromBlame } from './content/helpDates';
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
  getBlogPost,
  getBlogBreadcrumb,
  POSTS,
  BLOG_INDEX_PATH,
  blogPostPath,
  type BlogPost,
} from './content/blog';
import {
  OG_IMAGE_HEIGHT,
  OG_IMAGE_WIDTH,
  SITE_HOST,
  type OgCard,
} from './og-image';
import {
  PRIVACY_DESCRIPTION,
  PRIVACY_PATH,
  PRIVACY_TITLE,
} from './content/privacy';
import {
  SUPPORT_DESCRIPTION,
  SUPPORT_PATH,
  SUPPORT_TITLE,
} from './content/support';

export const SITE_URL = `https://${SITE_HOST}`;

const TITLE = 'Thought Reps: write it down, it comes back';
const DESCRIPTION =
  'A notebook for iPhone that hands your ideas back to you. Write a thought in five seconds and it returns a week later. No account, stays on your phone.';
const HELP_TITLE = 'Help center | Thought Reps';
const HELP_DESCRIPTION =
  'Guides for Thought Reps, the iPhone notebook that brings your ideas back. Learn to write, resurface, review, back up and move your thoughts.';
const HELP_ARTICLE_TITLE_SUFFIX = ' | Thought Reps Help';
const BLOG_TITLE = 'Blog: keep what you learn | Thought Reps';
const BLOG_DESCRIPTION =
  'Essays from Thought Reps on commonplace books, rereading your notes, and keeping the ideas worth keeping.';
const BLOG_TITLE_SUFFIX = ' | Thought Reps';
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

export const BLOG_ROUTES: Route[] = [
  { path: BLOG_INDEX_PATH, file: 'blog/index.html', hydrate: false },
  ...POSTS.map((post) => ({
    path: blogPostPath(post.slug),
    file: `blog/${post.slug}/index.html`,
    hydrate: false,
  })),
];

export const ROUTES: Route[] = [
  { path: '/', file: 'index.html', hydrate: true },
  ...HELP_ROUTES,
  ...BLOG_ROUTES,
  { path: PRIVACY_PATH, file: 'privacy/index.html', hydrate: false },
  { path: SUPPORT_PATH, file: 'support/index.html', hydrate: false },
  { path: '/404', file: '404.html', hydrate: false, noindex: true },
];

export interface PageMeta {
  title: string;
  description?: string;
  canonical?: string;
  noindex?: boolean;
  jsonLd: object[];
  /** The link-preview card; prerender renders it to the page's og:image. */
  ogCard: OgCard;
}

const HOME_OG_CARD: OgCard = { kind: 'home' };

// The export download page (transfer-web) is static, so its og:image can't
// carry a content hash. Prerender writes this card to EXPORT_LINK_OG_IMAGE
// on the landing site, and transfer-web/index.html links it there.
export const EXPORT_LINK_OG_CARD: OgCard = {
  kind: 'page',
  title: 'Your Thought Reps export',
  host: `transfer.${SITE_HOST}`,
  path: '',
};

function pageCard(title: string, path: string): OgCard {
  return { kind: 'page', title, host: SITE_HOST, path };
}
export const EXPORT_LINK_OG_IMAGE = 'og/export-link.png';

export { renderOgImage } from './og-image';

/** The help source file prerender blames for each article's date. */
export function helpDatesSourceFile(): string {
  return HELP_SOURCE_FILE;
}

/** Help article dates from `git blame --line-porcelain` output on help.ts. */
export function helpDatesFromGitBlame(
  porcelain: string,
): Record<string, string> {
  return helpDatesFromBlame(
    porcelain,
    HELP_ARTICLES.map((a) => a.slug),
  );
}

/** Dates only prerender knows (from git). Without them, pages render undated. */
export interface SiteDates {
  /** Help article slug -> ISO date of its last change. */
  help?: Record<string, string>;
}

export function breadcrumbJsonLd(
  items: { name: string; path: string }[],
): object {
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: items.map((item, i) => ({
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

export function blogPostingJsonLd(post: BlogPost): object {
  const url = SITE_URL + blogPostPath(post.slug);
  const organization = {
    '@type': 'Organization',
    name: 'Thought Reps',
    url: `${SITE_URL}/`,
  };
  return {
    '@context': 'https://schema.org',
    '@type': 'BlogPosting',
    headline: post.title,
    description: post.description,
    datePublished: post.published,
    dateModified: post.updated ?? post.published,
    mainEntityOfPage: url,
    url,
    author: organization,
    publisher: organization,
  };
}

function blogPostFor(path: string): BlogPost | undefined {
  const prefix = `${BLOG_INDEX_PATH}/`;
  return path.startsWith(prefix)
    ? getBlogPost(path.slice(prefix.length))
    : undefined;
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
      ogCard: HOME_OG_CARD,
    };
  }
  if (path === PRIVACY_PATH) {
    return {
      title: PRIVACY_TITLE,
      description: PRIVACY_DESCRIPTION,
      canonical: SITE_URL + PRIVACY_PATH,
      jsonLd: [],
      ogCard: pageCard('Privacy policy', PRIVACY_PATH),
    };
  }
  if (path === SUPPORT_PATH) {
    return {
      title: SUPPORT_TITLE,
      description: SUPPORT_DESCRIPTION,
      canonical: SITE_URL + SUPPORT_PATH,
      jsonLd: [],
      ogCard: pageCard('Get help with Thought Reps', SUPPORT_PATH),
    };
  }
  if (path === HELP_INDEX_PATH) {
    return {
      title: HELP_TITLE,
      description: HELP_DESCRIPTION,
      canonical: SITE_URL + HELP_INDEX_PATH,
      jsonLd: [],
      ogCard: pageCard('Help center', HELP_INDEX_PATH),
    };
  }
  const article = helpArticleFor(path);
  if (article) {
    return {
      title: article.title + HELP_ARTICLE_TITLE_SUFFIX,
      description: article.description,
      canonical: SITE_URL + helpArticlePath(article.slug),
      jsonLd: [
        breadcrumbJsonLd(getHelpBreadcrumb(article)),
        ...(article.faq ? [faqJsonLd(article)] : []),
      ],
      ogCard: pageCard(article.title, helpArticlePath(article.slug)),
    };
  }
  if (path === BLOG_INDEX_PATH) {
    return {
      title: BLOG_TITLE,
      description: BLOG_DESCRIPTION,
      canonical: SITE_URL + BLOG_INDEX_PATH,
      jsonLd: [],
      ogCard: pageCard('Blog', BLOG_INDEX_PATH),
    };
  }
  const post = blogPostFor(path);
  if (post) {
    return {
      title: post.title + BLOG_TITLE_SUFFIX,
      description: post.description,
      canonical: SITE_URL + blogPostPath(post.slug),
      jsonLd: [
        breadcrumbJsonLd(getBlogBreadcrumb(post)),
        blogPostingJsonLd(post),
      ],
      ogCard: pageCard(post.title, blogPostPath(post.slug)),
    };
  }
  return {
    title: NOT_FOUND_TITLE,
    noindex: true,
    jsonLd: [],
    ogCard: HOME_OG_CARD,
  };
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** og:image URL for a card file under dist/ (e.g. `og/help-abc123.png`). */
export function ogImageUrl(file: string): string {
  return `${SITE_URL}/${file}`;
}

/**
 * Open Graph and Twitter tags. Without an image URL (tests, dev) the tags
 * still render but no image is linked.
 */
export function renderOgTags(meta: PageMeta, imageUrl?: string): string[] {
  const title = escapeHtml(meta.title);
  const tags = [
    '<meta property="og:type" content="website" />',
    '<meta property="og:site_name" content="Thought Reps" />',
    `<meta property="og:title" content="${title}" />`,
  ];
  if (meta.description) {
    tags.push(
      `<meta property="og:description" content="${escapeHtml(meta.description)}" />`,
    );
  }
  if (meta.canonical) {
    tags.push(
      `<meta property="og:url" content="${escapeHtml(meta.canonical)}" />`,
    );
  }
  if (imageUrl) {
    tags.push(
      `<meta property="og:image" content="${escapeHtml(imageUrl)}" />`,
      `<meta property="og:image:width" content="${OG_IMAGE_WIDTH}" />`,
      `<meta property="og:image:height" content="${OG_IMAGE_HEIGHT}" />`,
      `<meta property="og:image:alt" content="${title}" />`,
      '<meta name="twitter:card" content="summary_large_image" />',
    );
  }
  return tags;
}

export function renderHead(meta: PageMeta, ogImage?: string): string {
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
  tags.push(...renderOgTags(meta, ogImage));
  for (const data of meta.jsonLd) {
    tags.push(
      `<script type="application/ld+json">${JSON.stringify(data).replace(/</g, '\\u003c')}</script>`,
    );
  }
  return tags.join('\n    ');
}

function renderPage(path: string, dates: SiteDates = {}): string {
  if (path === '/') return renderToString(<LandingPage />);
  if (path === PRIVACY_PATH) return renderToString(<PrivacyPolicyPage />);
  if (path === SUPPORT_PATH) return renderToString(<SupportPage />);
  if (path === HELP_INDEX_PATH) return renderToString(<HelpIndexPage />);
  const article = helpArticleFor(path);
  if (article) {
    return renderToString(
      <HelpArticlePage
        article={article}
        updated={dates.help?.[article.slug]}
      />,
    );
  }
  if (path === BLOG_INDEX_PATH) return renderToString(<BlogIndexPage />);
  const post = blogPostFor(path);
  if (post) return renderToString(<BlogPostPage post={post} />);
  return renderToString(<NotFoundPage />);
}

export function renderRoute(
  path: string,
  ogImage?: string,
  dates?: SiteDates,
): { html: string; head: string } {
  return {
    html: renderPage(path, dates),
    head: renderHead(getPageMeta(path), ogImage),
  };
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
  ogImage?: string,
  dates?: SiteDates,
): string {
  if (!HEAD_MARKER.test(template) || !template.includes(OUTLET_MARKER)) {
    throw new Error(
      'index.html is missing the ssr-head/ssr-outlet markers. Run `vite build` first; prerender is not re-runnable on its own output.',
    );
  }
  const { html, head } = renderRoute(route.path, ogImage, dates);
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
