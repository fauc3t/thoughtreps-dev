import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import reactHooks from 'eslint-plugin-react-hooks';
import reactRefresh from 'eslint-plugin-react-refresh';
import prettierConfig from 'eslint-config-prettier';
import globals from 'globals';

export default tseslint.config(
  {
    // Lints only infra/, site-landing/, transfer-web/ and scripts/. The Swift app, designs/,
    // landing/ (HTML prototypes) and the repo's docs are not ours to lint.
    ignores: [
      '**/node_modules/**',
      '.claude/**',
      '**/dist/**',
      '**/dist-server/**',
      '**/cdk.out/**',
      '**/coverage/**',
      '**/*.d.ts',
      'ThoughtReps/**',
      'ThoughtRepsShare/**',
      'ThoughtRepsTests/**',
      'ThoughtReps.xcodeproj/**',
      'Shared/**',
      'Config/**',
      'design-assets/**',
      'designs/**',
      'landing/**',
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    languageOptions: {
      globals: { ...globals.node },
    },
  },
  {
    files: [
      'infra/mail-web/src/**/*.{ts,tsx}',
      'site-landing/src/**/*.{ts,tsx}',
      'transfer-web/src/**/*.{ts,tsx}',
    ],
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
    },
    languageOptions: {
      globals: { ...globals.browser },
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': [
        'warn',
        { allowConstantExport: true },
      ],
    },
  },
  // Must stay last: turns off stylistic rules that would otherwise fight
  // with prettier's own formatting.
  prettierConfig,
);
