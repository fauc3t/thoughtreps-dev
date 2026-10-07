// Link-preview cards (og:image / twitter:image), rendered at build time by
// scripts/prerender.mjs with satori (JSX -> SVG) and resvg (SVG -> PNG), the
// same pipeline as strands.io's marketing cards. Only the SSR bundle imports
// this; satori and resvg stay external there, so this runs from
// dist-server/ and resolves fonts from node_modules like any Node script.
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { Resvg } from '@resvg/resvg-js';
import satori, { type Font } from 'satori';
import iconSvg from '../public/favicon.svg?raw';

export const OG_IMAGE_WIDTH = 1200;
export const OG_IMAGE_HEIGHT = 630;

/** The brand card: icon, name and pitch. Also used for the 404 page. */
export interface HomeOgCard {
  kind: 'home';
}

/** Every other page: its title and address (`host` + `path`). */
export interface PageOgCard {
  kind: 'page';
  title: string;
  host: string;
  path: string;
}

export const SITE_HOST = 'thoughtreps.com';

export type OgCard = HomeOgCard | PageOgCard;

// The light palette from index.css. Cards are always light: they're shown
// inside other apps, which don't know our theme.
const PAPER = '#ffffff';
const INK = '#111214';
const MUTED = '#5e6066';

const ICON_DATA_URI = `data:image/svg+xml;base64,${btoa(iconSvg)}`;

// satori needs real font bytes and can't read woff2 or variable fonts, so
// the display face is static Archivo (@fontsource/archivo) rather than the
// site's Archivo Variable. Read lazily so tests that import entry-server
// without rendering a card don't touch the disk.
let fonts: Font[] | undefined;
function loadFonts(): Font[] {
  if (fonts) return fonts;
  const require = createRequire(import.meta.url);
  const file = (path: string) => readFileSync(require.resolve(path));
  fonts = [
    {
      name: 'Archivo',
      data: file('@fontsource/archivo/files/archivo-latin-800-normal.woff'),
      weight: 800,
      style: 'normal',
    },
    {
      name: 'Archivo',
      data: file('@fontsource/archivo/files/archivo-latin-900-normal.woff'),
      weight: 900,
      style: 'normal',
    },
    {
      name: 'IBM Plex Sans',
      data: file(
        '@fontsource/ibm-plex-sans/files/ibm-plex-sans-latin-400-normal.woff',
      ),
      weight: 400,
      style: 'normal',
    },
    {
      name: 'IBM Plex Mono',
      data: file(
        '@fontsource/ibm-plex-mono/files/ibm-plex-mono-latin-500-normal.woff',
      ),
      weight: 500,
      style: 'normal',
    },
  ];
  return fonts;
}

// Title sizes tried largest first. satori can't measure text before
// rendering, so line count is estimated from character count (a greedy word
// wrap); it only has to keep real titles within TITLE_MAX_LINES.
const TITLE_FONT_SIZES = [92, 80, 70, 60] as const;
const TITLE_MAX_LINES = 2;
const PAGE_PADDING = 72;
const TITLE_COLUMN_WIDTH = OG_IMAGE_WIDTH - 2 * PAGE_PADDING;
// Average advance of Archivo Black, as a fraction of the font size.
const AVG_CHAR_WIDTH_EM = 0.6;

function estimateLineCount(title: string, fontSize: number): number {
  const perLine = Math.max(
    1,
    Math.floor(TITLE_COLUMN_WIDTH / (fontSize * AVG_CHAR_WIDTH_EM)),
  );
  let lines = 1;
  let length = 0;
  for (const word of title.split(' ')) {
    const added = word.length + (length > 0 ? 1 : 0);
    if (length > 0 && length + added > perLine) {
      lines += 1;
      length = word.length;
    } else {
      length += added;
    }
  }
  return lines;
}

export function pickTitleFontSize(title: string): number {
  return (
    TITLE_FONT_SIZES.find(
      (size) => estimateLineCount(title, size) <= TITLE_MAX_LINES,
    ) ?? TITLE_FONT_SIZES[TITLE_FONT_SIZES.length - 1]
  );
}

// The card's parts are plain functions returning elements, not components:
// satori only needs the element tree, and this file isn't a React module.
function icon(size: number) {
  return (
    <img
      src={ICON_DATA_URI}
      width={size}
      height={size}
      style={{
        borderRadius: size * 0.23,
        border: `${Math.round(size / 30)}px solid ${INK}`,
        boxShadow: `${Math.round(size / 17)}px ${Math.round(size / 17)}px 0 ${INK}`,
      }}
    />
  );
}

function wordmark(fontSize: number) {
  return (
    <span
      style={{
        fontFamily: 'Archivo',
        fontWeight: 900,
        fontSize,
        lineHeight: 1,
        letterSpacing: -fontSize * 0.03,
      }}
    >
      Thought Reps
    </span>
  );
}

// The page's address in a sticker-style box. On page cards the path is the
// dark part, so it reads as "this page"; the host is muted.
function urlChip(host: string, path = '') {
  return (
    <div
      style={{
        display: 'flex',
        padding: '12px 22px',
        border: `3px solid ${INK}`,
        borderRadius: 14,
        boxShadow: `4px 4px 0 ${INK}`,
        fontFamily: 'IBM Plex Mono',
        fontWeight: 500,
        fontSize: 26,
        letterSpacing: 0.5,
      }}
    >
      <span style={{ color: path ? MUTED : INK }}>{host}</span>
      {path ? <span>{path}</span> : null}
    </div>
  );
}

// The brand card: a large app icon and name, the pitch and the domain.
function homeCard() {
  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: 44,
        width: OG_IMAGE_WIDTH,
        height: OG_IMAGE_HEIGHT,
        backgroundColor: PAPER,
        color: INK,
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 36 }}>
        {icon(150)}
        {wordmark(104)}
      </div>
      <span
        style={{
          fontFamily: 'IBM Plex Sans',
          fontSize: 36,
          lineHeight: 1.3,
          color: MUTED,
        }}
      >
        Spaced repetition thought log
      </span>
      {urlChip(SITE_HOST)}
    </div>
  );
}

// Every other page: the brand at the top, the page title, and its address.
function pageCard(card: PageOgCard) {
  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'space-between',
        width: OG_IMAGE_WIDTH,
        height: OG_IMAGE_HEIGHT,
        padding: PAGE_PADDING,
        backgroundColor: PAPER,
        color: INK,
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 24 }}>
        {icon(84)}
        {wordmark(52)}
      </div>
      <div
        style={{
          display: 'flex',
          fontFamily: 'Archivo',
          fontWeight: 900,
          fontSize: pickTitleFontSize(card.title),
          lineHeight: 1.0,
          letterSpacing: -2,
        }}
      >
        {card.title}
      </div>
      <div style={{ display: 'flex' }}>{urlChip(card.host, card.path)}</div>
    </div>
  );
}

function cardElement(card: OgCard) {
  return card.kind === 'home' ? homeCard() : pageCard(card);
}

export async function renderOgImage(card: OgCard): Promise<Uint8Array> {
  const svg = await satori(cardElement(card), {
    width: OG_IMAGE_WIDTH,
    height: OG_IMAGE_HEIGHT,
    fonts: loadFonts(),
  });
  return new Resvg(svg).render().asPng();
}
