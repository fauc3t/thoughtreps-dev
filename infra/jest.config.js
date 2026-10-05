// package.json sets "type": "module" for this package (to match the
// NodeNext ESM-authoring convention lib/*.ts uses — see the comment below),
// so this config file is itself loaded as ESM by Jest — `export default`,
// not `module.exports`.
export default {
  testEnvironment: 'node',
  // lambda/ added alongside test/ so lambda/**/*.test.ts (the mail
  // Lambdas' pure-function unit tests, colocated with their source rather
  // than living under test/) gets picked up too.
  roots: ['<rootDir>/test', '<rootDir>/lambda'],
  testMatch: ['**/*.test.ts'],
  transform: {
    '^.+\\.tsx?$': ['@swc/jest'],
  },
  // Source in this package uses `.js`-suffixed relative imports even though
  // the files are `.ts` (standard NodeNext ESM-output convention — see
  // tsconfig.json's own module/moduleResolution settings). @swc/jest transpiles that import
  // syntax down to a plain `require()` for Jest's own CommonJS-based module
  // system, but it doesn't rewrite the `.js` specifier back to the `.ts`
  // source on its own — without this, every test importing a `lib/*.ts`
  // stack file fails to resolve.
  moduleNameMapper: {
    '^(\\.{1,2}/.*)\\.js$': '$1',
  },
  setupFilesAfterEnv: ['aws-cdk-lib/testhelpers/jest-autoclean'],
};
