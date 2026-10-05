// Loaded once before every test file (see vite.config.ts's test.setupFiles).
// The /vitest subpath registers jest-dom's matchers (toBeInTheDocument,
// toHaveTextContent, ...) on vitest's own `expect`, rather than the plain
// '@testing-library/jest-dom' entry point, which assumes a Jest global.
import '@testing-library/jest-dom/vitest';
import { afterEach } from 'vitest';
import { cleanup } from '@testing-library/react';

// @testing-library/react only auto-registers this itself when `test.globals`
// is on (it detects a global `afterEach`) — this repo doesn't turn that on,
// so cleanup after every test is wired by hand instead. Without it, each
// test's rendered tree stays mounted into the next test's jsdom document, so
// a second render of the same component makes every query see two matches
// instead of one.
afterEach(() => {
  cleanup();
});

// jsdom doesn't implement ResizeObserver at all — stub it in case any
// component (now or later) reads element dimensions via it. A no-op is
// fine here: layout measurement doesn't matter in jsdom, only that the
// callback exists.
class ResizeObserverStub {
  observe() {}
  unobserve() {}
  disconnect() {}
}
globalThis.ResizeObserver ??= ResizeObserverStub;

// jsdom doesn't implement matchMedia either. Defaults to non-matching;
// tests that care can override per-test via `vi.spyOn(window, 'matchMedia')`.
window.matchMedia ??= (query: string) =>
  ({
    matches: false,
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  }) as MediaQueryList;
