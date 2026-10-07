// @vitest-environment node
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  EXPORT_LINK_OG_CARD,
  EXPORT_LINK_OG_IMAGE,
  getPageMeta,
  ogImageUrl,
  renderHead,
  renderOgImage,
  ROUTES,
} from './entry-server';
import { OG_IMAGE_HEIGHT, OG_IMAGE_WIDTH } from './og-image';

function pngSize(png: Uint8Array): { width: number; height: number } {
  const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
  // The IHDR chunk follows the 8-byte signature and 8 bytes of chunk header.
  return { width: view.getUint32(16), height: view.getUint32(20) };
}

describe('Open Graph tags', () => {
  it('gives every route a title, an image and a large Twitter card', () => {
    for (const route of ROUTES) {
      const meta = getPageMeta(route.path);
      const head = renderHead(meta, 'https://thoughtreps.com/og/x.png');
      expect(head, route.path).toContain('<meta property="og:title"');
      expect(head, route.path).toContain(
        '<meta property="og:image" content="https://thoughtreps.com/og/x.png" />',
      );
      expect(head, route.path).toContain(
        `<meta property="og:image:width" content="${OG_IMAGE_WIDTH}" />`,
      );
      expect(head, route.path).toContain(
        '<meta name="twitter:card" content="summary_large_image" />',
      );
    }
  });

  it('points og:url at the canonical URL and repeats the description', () => {
    for (const route of ROUTES.filter((r) => !r.noindex)) {
      const meta = getPageMeta(route.path);
      const head = renderHead(meta);
      expect(head, route.path).toContain(
        `<meta property="og:url" content="${meta.canonical}" />`,
      );
      expect(head, route.path).toContain('<meta property="og:description"');
    }
  });

  it('links no image when none was rendered', () => {
    const head = renderHead(getPageMeta('/'));
    expect(head).not.toContain('og:image');
    expect(head).not.toContain('twitter:card');
  });

  it("matches transfer-web's static og:image to the card prerender writes", () => {
    const html = readFileSync(
      resolve(__dirname, '../../transfer-web/index.html'),
      'utf8',
    );
    expect(html).toContain(
      `<meta property="og:image" content="${ogImageUrl(EXPORT_LINK_OG_IMAGE)}" />`,
    );
  });
});

describe('og image', () => {
  it('renders the home and page cards as 1200x630 PNGs', async () => {
    for (const card of [getPageMeta('/').ogCard, EXPORT_LINK_OG_CARD]) {
      const png = await renderOgImage(card);
      expect(Array.from(png.subarray(1, 4))).toEqual([0x50, 0x4e, 0x47]);
      expect(pngSize(png)).toEqual({
        width: OG_IMAGE_WIDTH,
        height: OG_IMAGE_HEIGHT,
      });
    }
  });
});
