// Renders every App Store header option into static/ (PNG) and motion/ (MP4). Run: node gen.mjs [name-substring]
// Needs Playwright's Chromium and ffmpeg. Playwright is not a repo dependency: it is resolved via npx.
// First run: `npx playwright@1.63 install chromium` (downloads the browser to ~/Library/Caches/ms-playwright).
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const only = process.argv[2] ?? '';
const src = (page, q = '') => pathToFileURL(join(here, 'src', page)).href + q;

const FPS = 30, SECONDS = 12;
const SIZES = [['5244x2950', 5244, 2950], ['3840x1646', 3840, 1646]];
const STATIC = [
  { name: 'A-headline', page: 'headline.html' },
  { name: 'A-headline-dark', page: 'headline.html', q: '?theme=dark' },
  { name: 'B-card-stack', page: 'deck.html', arg: 0 },
  { name: 'C-timeline', page: 'timeline.html', arg: 0 },
];
const MOTION = [
  { name: 'A-card-swing', page: 'deck.html', arg: (i) => i / FPS },
  { name: 'B-timeline-drift', page: 'timeline.html', arg: (i) => (3 * i) / (FPS * SECONDS) },
];

const loadPlaywright = async () => {
  try {
    return await import('playwright');
  } catch {
    const cli = execFileSync('npx', ['-y', '-p', 'playwright@1.63', 'sh', '-c', 'readlink -f "$(command -v playwright)"'], { encoding: 'utf8' }).trim();
    return await import(pathToFileURL(join(dirname(cli), 'index.mjs')).href);
  }
};

const { chromium } = await loadPlaywright();
let browser;
let tmp;

const open = async (job, w, h) => {
  const page = await browser.newPage({ viewport: { width: w, height: h } });
  await page.goto(src(job.page, job.q));
  await page.evaluate(() => document.fonts.ready);
  return page;
};

try {
  try {
    browser = await chromium.launch();
  } catch (e) {
    throw new Error(`Chromium not available (run \`npx playwright@1.63 install chromium\`): ${e.message}`);
  }
  tmp = mkdtempSync(join(tmpdir(), 'header-'));
  mkdirSync(join(here, 'static'), { recursive: true });
  mkdirSync(join(here, 'motion'), { recursive: true });
  for (const job of STATIC.filter((j) => j.name.includes(only))) {
    for (const [label, w, h] of SIZES) {
      const page = await open(job, w, h);
      await page.evaluate((a) => render(a), job.arg ?? 0);
      const raw = join(tmp, 'raw.png');
      await page.screenshot({ path: raw });
      await page.close();
      // Chromium writes RGBA; the App Store rejects an alpha channel.
      const out = join(here, 'static', `${job.name}-${label}.png`);
      execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', raw, '-pix_fmt', 'rgb24', '-compression_level', '9', out]);
      console.log(out);
    }
  }
  for (const job of MOTION.filter((j) => j.name.includes(only))) {
    const frames = join(tmp, job.name);
    mkdirSync(frames);
    const page = await open(job, 3840, 1646);
    // Frame FPS*SECONDS would equal frame 0, so it is left out and the clip loops seamlessly.
    for (let i = 0; i < FPS * SECONDS; i++) {
      await page.evaluate((a) => render(a), job.arg(i));
      await page.screenshot({ path: join(frames, `${String(i).padStart(4, '0')}.png`) });
    }
    await page.close();
    const out = join(here, 'motion', `${job.name}-3840x1646.mp4`);
    execFileSync('ffmpeg', ['-y', '-v', 'error', '-framerate', String(FPS), '-i', join(frames, '%04d.png'),
      '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p', '-c:v', 'libx264', '-preset', 'slow', '-crf', '16',
      '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-r', String(FPS), '-an', '-movflags', '+faststart', out]);
    console.log(out);
  }
} finally {
  await browser?.close();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
}
