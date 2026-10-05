import { useSyncExternalStore } from 'react';

const dateFormat = new Intl.DateTimeFormat('en-US', {
  weekday: 'short',
  month: 'short',
  day: 'numeric',
});

const subscribe = () => () => {};

/** Returns a "days from today" formatter, or null on the server and during hydration (there is no meaningful "today" at build time). */
export function useDateFromToday(): ((days: number) => string) | null {
  const mounted = useSyncExternalStore(
    subscribe,
    () => true,
    () => false,
  );
  if (!mounted) return null;
  return (days) => {
    const d = new Date();
    d.setDate(d.getDate() + days);
    return dateFormat.format(d);
  };
}
