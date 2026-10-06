import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const SCRIPT = readFileSync(resolve(__dirname, '../public/theme.js'), 'utf8');
const root = document.documentElement;

function run(osDark: boolean) {
  vi.stubGlobal('matchMedia', () => ({ matches: osDark }));
  new Function(SCRIPT)();
}

function click() {
  const button = document.createElement('button');
  button.setAttribute('data-theme-toggle', '');
  button.innerHTML = '<svg><path /></svg>';
  document.body.append(button);
  button
    .querySelector('path')!
    .dispatchEvent(new MouseEvent('click', { bubbles: true }));
  button.remove();
}

describe('theme.js', () => {
  let listeners: EventListenerOrEventListenerObject[] = [];
  beforeEach(() => {
    const add = document.addEventListener.bind(document);
    vi.spyOn(document, 'addEventListener').mockImplementation(
      (type, listener, options) => {
        listeners.push(listener);
        add(type, listener, options);
      },
    );
  });
  afterEach(() => {
    for (const l of listeners) document.removeEventListener('click', l);
    listeners = [];
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    localStorage.clear();
    root.removeAttribute('data-theme');
  });

  it('applies a saved choice before paint', () => {
    localStorage.setItem('theme', 'dark');
    run(false);
    expect(root.getAttribute('data-theme')).toBe('dark');
  });

  it('ignores junk in storage', () => {
    localStorage.setItem('theme', 'purple');
    run(false);
    expect(root.hasAttribute('data-theme')).toBe(false);
  });

  it('flips away from the OS theme and back to following it', () => {
    run(false);
    click();
    expect(root.getAttribute('data-theme')).toBe('dark');
    expect(localStorage.getItem('theme')).toBe('dark');
    click();
    expect(root.hasAttribute('data-theme')).toBe(false);
    expect(localStorage.getItem('theme')).toBeNull();
  });

  it('starts from dark when the OS is dark', () => {
    run(true);
    click();
    expect(root.getAttribute('data-theme')).toBe('light');
    expect(localStorage.getItem('theme')).toBe('light');
  });

  it('ignores clicks elsewhere', () => {
    run(false);
    document.body.click();
    expect(root.hasAttribute('data-theme')).toBe(false);
  });
});
