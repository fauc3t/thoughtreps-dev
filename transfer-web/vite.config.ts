import { defineConfig, type Plugin } from 'vitest/config';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

const CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self'",
  "font-src 'self' data:",
  "img-src 'self'",
  "connect-src 'self' https://*.amazonaws.com",
  "base-uri 'none'",
  "form-action 'none'",
].join('; ');

// Build only: the dev server injects inline scripts that this policy blocks.
const cspMeta: Plugin = {
  name: 'csp-meta',
  apply: 'build',
  transformIndexHtml: () => [
    {
      tag: 'meta',
      attrs: { 'http-equiv': 'Content-Security-Policy', content: CSP },
      injectTo: 'head-prepend',
    },
  ],
};

export default defineConfig({
  plugins: [react(), tailwindcss(), cspMeta],
  test: {
    environment: 'jsdom',
  },
});
