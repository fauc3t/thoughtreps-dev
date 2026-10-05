// Writes each route's prerendered page into dist/ using the bundle built by
// `vite build --ssr`. The page logic lives in src/entry-server.tsx (buildPage).
import { readFile, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dist = resolve(root, 'dist');
const { buildPage, ROUTES } = await import(
  pathToFileURL(resolve(root, 'dist-server/entry-server.js')).href
);

const template = await readFile(resolve(dist, 'index.html'), 'utf8');

for (const route of ROUTES) {
  await writeFile(resolve(dist, route.file), buildPage(template, route));
}
