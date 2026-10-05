// defineConfig from 'vitest/config' (not plain 'vite') so this one file can
// carry both the app's build config and its `test` block — no separate
// vitest.config.ts to keep in sync with plugins defined below.
import { configDefaults, defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // amazon-cognito-identity-js (lib/auth.ts) expects Node's `global` —
  // undefined in a browser, and Vite doesn't polyfill it automatically the
  // way webpack/CRA did. postal-mime needs no equivalent shim — it's
  // genuinely browser-native, unlike the Cognito library.
  define: { global: 'globalThis' },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    exclude: [...configDefaults.exclude],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html'],
      include: ['src/**/*.{ts,tsx}'],
      exclude: ['src/**/*.test.{ts,tsx}', 'src/test/**', 'src/main.tsx'],
    },
  },
});
