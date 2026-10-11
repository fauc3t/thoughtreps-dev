import { useSyncExternalStore } from 'react';

export interface Joined {
  /** Held in memory for this page view only; never written to storage. */
  email: string | null;
  beta: boolean;
}

const KEY = 'thoughtreps-waitlist-joined';
const listeners = new Set<() => void>();
let joined: Joined | null | undefined;

function readStored(): Joined | null {
  try {
    const parsed: unknown = JSON.parse(sessionStorage.getItem(KEY) ?? 'null');
    if (parsed && typeof parsed === 'object') {
      if ('email' in parsed) {
        sessionStorage.removeItem(KEY);
        return null;
      }
      if (
        'joined' in parsed &&
        parsed.joined === true &&
        'beta' in parsed &&
        typeof parsed.beta === 'boolean'
      ) {
        return { email: null, beta: parsed.beta };
      }
    }
  } catch {
    // Storage blocked or unreadable: treat as not joined.
  }
  return null;
}

function getSnapshot(): Joined | null {
  if (joined === undefined) joined = readStored();
  return joined;
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function setWaitlistJoined(value: Joined | null) {
  joined = value;
  try {
    if (value) {
      sessionStorage.setItem(
        KEY,
        JSON.stringify({ joined: true, beta: value.beta }),
      );
    } else {
      sessionStorage.removeItem(KEY);
    }
  } catch {
    // Storage blocked: the joined state still holds for this page view.
  }
  listeners.forEach((l) => l());
}

/** Server and hydration render the signup form; the stored state applies after. */
export function useWaitlistJoined(): Joined | null {
  return useSyncExternalStore(subscribe, getSnapshot, () => null);
}
