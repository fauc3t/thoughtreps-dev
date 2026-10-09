// Renders the App Store screenshots into static/ (PNG, 1320x2868, RGB) from the simulator captures in raw/.
// Run: node gen.mjs [name-substring]            composite from raw/ only (Playwright, no Xcode)
//      node gen.mjs --capture [name-substring]  first re-capture raw/ in a dedicated simulator, then composite
// Needs Playwright's Chromium and ffmpeg. Playwright is not a repo dependency: it is resolved via npx.
// First run: `npx playwright@1.63 install chromium` (downloads the browser to ~/Library/Caches/ms-playwright).
// Brand CSS/JS and fonts are reused from ../Header/src and ../SearchResults/src.
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const capture = process.argv.includes('--capture');
const only = process.argv.slice(2).find((a) => !a.startsWith('--')) ?? '';
const NAMES = ['01-timeline', '02-interval', '03-markdown-photos', '04-search', '05-tags', '06-reminders'];
const W = 1320, H = 2868;

const SIM_NAME = 'ThoughtReps Screenshots';
const DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max';

const run = (cmd, args, opts = {}) => execFileSync(cmd, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'], ...opts });
const simctlJson = (...args) => JSON.parse(run('xcrun', ['simctl', ...args, '-j']));

// A dedicated simulator, so a session using the shared ones is never disturbed.
const ensureSimulator = () => {
  const find = () => Object.values(simctlJson('list', 'devices').devices).flat().find((d) => d.name === SIM_NAME && d.isAvailable);
  let sim = find();
  if (!sim) {
    if (!simctlJson('list', 'devicetypes').devicetypes.some((t) => t.identifier === DEVICE_TYPE)) {
      throw new Error(`Device type ${DEVICE_TYPE} (iPhone 18 Pro Max) is not installed. Update Xcode to a version that includes it, or change DEVICE_TYPE in gen.mjs to another 6.9" iPhone with a 1320x2868 screen (see \`xcrun simctl list devicetypes\`).`);
    }
    const runtimes = simctlJson('list', 'runtimes').runtimes.filter((r) => r.isAvailable && r.identifier.includes('.iOS-'));
    if (!runtimes.length) throw new Error('No iOS simulator runtime is installed');
    run('xcrun', ['simctl', 'create', SIM_NAME, DEVICE_TYPE, runtimes.at(-1).identifier]);
    sim = find();
  }
  const state = () => find().state;
  for (let i = 0; state() === 'Shutting Down'; i++) {
    if (i >= 30) throw new Error(`${SIM_NAME} is stuck shutting down; run \`xcrun simctl shutdown ${sim.udid}\` and retry`);
    run('sleep', ['1']);
  }
  // Restarted every run so it never starts on the Lock Screen. Not erased: on an erased simulator the
  // notification permission is granted but scheduling still fails until the next restart.
  if (state() !== 'Shutdown') run('xcrun', ['simctl', 'shutdown', sim.udid]);
  run('xcrun', ['simctl', 'boot', sim.udid]);
  run('xcrun', ['simctl', 'bootstatus', sim.udid, '-b']);
  run('xcrun', ['simctl', 'status_bar', sim.udid, 'override', '--time', '9:41', '--dataNetwork', 'wifi', '--wifiMode', 'active',
    '--wifiBars', '3', '--cellularMode', 'active', '--cellularBars', '4', '--operatorName', '', '--batteryState', 'charged', '--batteryLevel', '100']);
  return sim.udid;
};

const captureRaw = () => {
  const udid = ensureSimulator();
  const tmp = mkdtempSync(join(tmpdir(), 'screenshots-'));
  try {
    console.log('xcodegen');
    run('xcodegen', [], { cwd: root });
    const bundle = join(tmp, 'result.xcresult');
    console.log('xcodebuild test (about two minutes)');
    run('xcodebuild', ['test', '-scheme', 'ThoughtRepsScreenshots', '-destination', `platform=iOS Simulator,id=${udid}`,
      '-only-testing:ThoughtRepsUITests', '-resultBundlePath', bundle], { cwd: root, stdio: ['ignore', 'ignore', 'inherit'], maxBuffer: 1 << 30 });
    const out = join(tmp, 'attachments');
    run('xcrun', ['xcresulttool', 'export', 'attachments', '--path', bundle, '--output-path', out]);
    mkdirSync(join(here, 'raw'), { recursive: true });
    const seen = new Set();
    for (const test of JSON.parse(readFileSync(join(out, 'manifest.json'), 'utf8'))) {
      for (const a of test.attachments) {
        const name = a.suggestedHumanReadableName.replace(/_\d+_[0-9A-F-]{36}\.png$/, '');
        copyFileSync(join(out, a.exportedFileName), join(here, 'raw', `${name}.png`));
        seen.add(name);
      }
    }
    const missing = NAMES.filter((n) => !seen.has(n));
    if (missing.length) throw new Error(`Missing captures: ${missing.join(', ')}`);
    for (const n of NAMES) console.log(join(here, 'raw', `${n}.png`));
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
};

const loadPlaywright = async () => {
  try {
    return await import('playwright');
  } catch {
    const cli = execFileSync('npx', ['-y', '-p', 'playwright@1.63', 'sh', '-c', 'readlink -f "$(command -v playwright)"'], { encoding: 'utf8' }).trim();
    return await import(pathToFileURL(join(dirname(cli), 'index.mjs')).href);
  }
};

const composite = async () => {
  const { chromium } = await loadPlaywright();
  let browser;
  let tmp;
  try {
    try {
      browser = await chromium.launch();
    } catch (e) {
      throw new Error(`Chromium not available (run \`npx playwright@1.63 install chromium\`): ${e.message}`);
    }
    tmp = mkdtempSync(join(tmpdir(), 'screenshots-'));
    mkdirSync(join(here, 'static'), { recursive: true });
    for (const name of NAMES.filter((n) => n.includes(only))) {
      if (!existsSync(join(here, 'raw', `${name}.png`))) throw new Error(`raw/${name}.png is missing; run with --capture`);
      const page = await browser.newPage({ viewport: { width: W, height: H } });
      await page.goto(pathToFileURL(join(here, 'src', 'shot.html')).href);
      await page.evaluate((n) => render(n), name);
      const png = join(tmp, 'shot.png');
      await page.screenshot({ path: png });
      await page.close();
      // Chromium writes RGBA; the App Store rejects an alpha channel.
      const out = join(here, 'static', `${name}-${W}x${H}.png`);
      execFileSync('ffmpeg', ['-y', '-v', 'error', '-i', png, '-pix_fmt', 'rgb24', '-compression_level', '9', out]);
      console.log(out);
    }
  } finally {
    await browser?.close();
    if (tmp) rmSync(tmp, { recursive: true, force: true });
  }
};

if (capture) captureRaw();
await composite();
