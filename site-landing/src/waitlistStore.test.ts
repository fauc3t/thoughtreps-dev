import { act, renderHook } from '@testing-library/react';
import { createElement } from 'react';
import { renderToString } from 'react-dom/server';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const KEY = 'thoughtreps-waitlist-joined';

async function freshStore() {
  vi.resetModules();
  return import('./waitlistStore');
}

beforeEach(() => {
  sessionStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('waitlistStore', () => {
  it('reads a stored flag as joined without an address', async () => {
    sessionStorage.setItem(KEY, JSON.stringify({ joined: true, beta: true }));
    const { useWaitlistJoined } = await freshStore();
    const { result } = renderHook(() => useWaitlistJoined());
    expect(result.current).toEqual({ email: null, beta: true });
  });

  it('never writes the email to sessionStorage', async () => {
    const { setWaitlistJoined, useWaitlistJoined } = await freshStore();
    const { result } = renderHook(() => useWaitlistJoined());
    act(() => setWaitlistJoined({ email: 'secret@b.co', beta: false }));
    expect(result.current).toEqual({ email: 'secret@b.co', beta: false });
    expect(sessionStorage.getItem(KEY)).toBe(
      JSON.stringify({ joined: true, beta: false }),
    );
    expect(JSON.stringify({ ...sessionStorage })).not.toContain('secret@b.co');
  });

  it('keeps the address in memory for the page view, then falls back after a reload', async () => {
    const first = await freshStore();
    act(() => first.setWaitlistJoined({ email: 'a@b.co', beta: false }));
    const reloaded = await freshStore();
    const { result } = renderHook(() => reloaded.useWaitlistJoined());
    expect(result.current).toEqual({ email: null, beta: false });
  });

  it('clears an old stored value that contains an email', async () => {
    sessionStorage.setItem(
      KEY,
      JSON.stringify({ email: 'a@b.co', beta: true }),
    );
    const { useWaitlistJoined } = await freshStore();
    const { result } = renderHook(() => useWaitlistJoined());
    expect(result.current).toBeNull();
    expect(sessionStorage.getItem(KEY)).toBeNull();
  });

  it('ignores malformed JSON', async () => {
    sessionStorage.setItem(KEY, '{nope');
    const { useWaitlistJoined } = await freshStore();
    const { result } = renderHook(() => useWaitlistJoined());
    expect(result.current).toBeNull();
  });

  it.each([
    ['a string', '"hi"'],
    ['missing beta', '{"joined":true}'],
    ['joined not true', '{"joined":false,"beta":false}'],
    ['wrong types', '{"joined":"yes","beta":"yes"}'],
  ])('ignores a stored value with the wrong shape (%s)', async (_n, raw) => {
    sessionStorage.setItem(KEY, raw);
    const { useWaitlistJoined } = await freshStore();
    const { result } = renderHook(() => useWaitlistJoined());
    expect(result.current).toBeNull();
  });

  it('treats a throwing getItem as not joined', async () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new Error('blocked');
    });
    const { useWaitlistJoined } = await freshStore();
    const { result } = renderHook(() => useWaitlistJoined());
    expect(result.current).toBeNull();
  });

  it('renders null for the server and hydration pass even when a flag is stored', async () => {
    sessionStorage.setItem(KEY, JSON.stringify({ joined: true, beta: false }));
    const { useWaitlistJoined } = await freshStore();
    function Probe() {
      return createElement('p', null, String(useWaitlistJoined()));
    }
    expect(renderToString(createElement(Probe))).toContain('null');
    const { result } = renderHook(() => useWaitlistJoined());
    expect(result.current).toEqual({ email: null, beta: false });
  });

  it('notifies subscribers when joined is set', async () => {
    const { useWaitlistJoined, setWaitlistJoined } = await freshStore();
    const { result } = renderHook(() => useWaitlistJoined());
    expect(result.current).toBeNull();
    act(() => setWaitlistJoined({ email: 'x@y.co', beta: false }));
    expect(result.current).toEqual({ email: 'x@y.co', beta: false });
  });
});
