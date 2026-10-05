// Writes each route's prerendered page into dist/ using the bundle built by
// `vite build --ssr`. The page logic lives in src/entry-server.tsx (buildPage).
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dist = resolve(root, 'dist');
const { buildPage, ROUTES, robotsTxt, sitemapXml } = await import(
  pathToFileURL(resolve(root, 'dist-server/entry-server.js')).href
);

const template = await readFile(resolve(dist, 'index.html'), 'utf8');

for (const route of ROUTES) {
  const file = resolve(dist, route.file);
  await mkdir(dirname(file), { recursive: true });
  await writeFile(file, buildPage(template, route));
}

await writeFile(resolve(dist, 'sitemap.xml'), sitemapXml(ROUTES));
await writeFile(resolve(dist, 'robots.txt'), robotsTxt());
