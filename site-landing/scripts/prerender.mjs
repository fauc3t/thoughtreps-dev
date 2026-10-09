// Writes each route's prerendered page into dist/ using the bundle built by
// `vite build --ssr`. The page logic lives in src/entry-server.tsx (buildPage).
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dist = resolve(root, 'dist');
const {
  buildPage,
  EXPORT_LINK_OG_CARD,
  EXPORT_LINK_OG_IMAGE,
  getPageMeta,
  helpDatesFromGitBlame,
  helpDatesSourceFile,
  ogImageUrl,
  renderOgImage,
  ROUTES,
  robotsTxt,
  sitemapXml,
} = await import(
  pathToFileURL(resolve(root, 'dist-server/entry-server.js')).href
);

// Each help article's "Updated" date is its newest line in git. Without git
// (or history), pages still build, just undated.
function helpDates() {
  try {
    const blame = execFileSync(
      'git',
      ['blame', '--line-porcelain', '--', helpDatesSourceFile()],
      { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
    );
    return helpDatesFromGitBlame(blame);
  } catch (error) {
    console.warn(`Help dates unavailable, building undated: ${error.message}`);
    return {};
  }
}
const dates = { help: helpDates() };

const template = await readFile(resolve(dist, 'index.html'), 'utf8');
await mkdir(resolve(dist, 'og'), { recursive: true });

// Each card's file name carries a hash of its PNG, so a changed card gets a
// new URL (link-preview caches key on the URL) and an unchanged one keeps
// its URL between builds.
async function writeOgImage(route, card) {
  const png = await renderOgImage(card);
  const hash = createHash('sha256').update(png).digest('hex').slice(0, 10);
  const name =
    route.path === '/' ? 'home' : route.path.slice(1).replace(/\//g, '-');
  const file = `og/${name}-${hash}.png`;
  await writeFile(resolve(dist, file), png);
  return ogImageUrl(file);
}

for (const route of ROUTES) {
  const ogImage = await writeOgImage(route, getPageMeta(route.path).ogCard);
  const file = resolve(dist, route.file);
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, buildPage(template, route, ogImage, dates));
}

await writeFile(
  resolve(dist, EXPORT_LINK_OG_IMAGE),
  await renderOgImage(EXPORT_LINK_OG_CARD),
);
await writeFile(resolve(dist, 'sitemap.xml'), sitemapXml(ROUTES));
await writeFile(resolve(dist, 'robots.txt'), robotsTxt());
