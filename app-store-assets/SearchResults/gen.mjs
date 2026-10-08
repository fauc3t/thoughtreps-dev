// Renders every App Store Search Results option into static/ (PNG) and motion/ (MP4).
// Run: node gen.mjs [name-substring] [--still]   (--still skips the videos)
// Needs Playwright's Chromium and ffmpeg. Playwright is not a repo dependency: it is resolved via npx.
// First run: `npx playwright@1.63 install chromium` (downloads the browser to ~/Library/Caches/ms-playwright).
// Brand CSS/JS, fonts and the timeline drift are reused from ../Header/src.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const stillOnly = process.argv.includes('--still');
const only = process.argv.slice(2).find((a) => !a.startsWith('--')) ?? '';
const src = (page, q = '') => pathToFileURL(join(here, 'src', page)).href + q;

const FPS = 30, SECONDS = 12;
// The 16:9 size is a still only: App Store Connect rejects a 5244x2950 Search Results video (see README).
const SIZES = [['3840x2560', 3840, 2560, true], ['5244x2950', 5244, 2950, false]];
const OPTIONS = [
  { name: 'A-timeline-headline', page: 'timeline.html', q: '?headline=1', still: 0, at: (i) => (3 * i) / (FPS * SECONDS) },
  { name: 'B-timeline', page: 'timeline.html', still: 0, at: (i) => (3 * i) / (FPS * SECONDS) },
  { name: 'C-in-the-app', page: 'phone.html', still: 2, at: (i) => i / FPS },
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

const open = async (opt, w, h) => {
  const page = await browser.newPage({ viewport: { width: w, height: h } });
  await page.goto(src(opt.page, opt.q));
  await page.evaluate(() => document.fonts.ready);
  return page;
};

// Level 6.0 allows 3840x2560 at 30 fps (MaxFS 139,264 MBs, MaxMBPS 4,177,920).
const encode = (frames, out) =>
  execFileSync('ffmpeg', ['-y', '-v', 'error', '-framerate', String(FPS), '-i', join(frames, '%04d.png'),
    '-vf', 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p', '-c:v', 'libx264', '-profile:v', 'high', '-level', '6.0',
    '-preset', 'slow', '-crf', '18', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709',
    '-r', String(FPS), '-an', '-movflags', '+faststart', out]);

try {
  try {
    browser = await chromium.launch();
  } catch (e) {
    throw new Error(`Chromium not available (run \`npx playwright@1.63 install chromium\`): ${e.message}`);
  }
  tmp = mkdtempSync(join(tmpdir(), 'search-results-'));
  mkdirSync(join(here, 'static'), { recursive: true });
  mkdirSync(join(here, 'motion'), { recursive: true });
  for (const opt of OPTIONS.filter((o) => o.name.includes(only))) {
    for (const [label, w, h, video] of SIZES) {
      const page = await open(opt, w, h);
      await page.evaluate((a) => render(a), opt.still);
      const raw = join(tmp, 'raw.png');
      await page.screenshot({ path: raw });
      // Chromium writes RGBA; the App Store rejects an alpha channel.
      const png = join(here, 'static', `${opt.name}-${label}.png`);
      execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', raw, '-pix_fmt', 'rgb24', '-compression_level', '9', png]);
      console.log(png);
      if (stillOnly || !video) {
        await page.close();
        continue;
      }

      const frames = join(tmp, `${opt.name}-${label}`);
      mkdirSync(frames);
      // Frame FPS*SECONDS would equal frame 0, so it is left out and the clip loops seamlessly.
      for (let i = 0; i < FPS * SECONDS; i++) {
        await page.evaluate((a) => render(a), opt.at(i));
        await page.screenshot({ path: join(frames, `${String(i).padStart(4, '0')}.png`) });
      }
      await page.close();
      const mp4 = join(here, 'motion', `${opt.name}-${label}.mp4`);
      encode(frames, mp4);
      rmSync(frames, { recursive: true, force: true });
      console.log(mp4);
    }
  }
} finally {
  await browser?.close();
  if (tmp) rmSync(tmp, { recursive: true, force: true });
}
