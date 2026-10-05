import { createContext, useContext } from 'react';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';

// Shared state read from more than one place (every protected page, plus
// queries/messages.ts and queries/message.ts) — exposed through the
// useSession hook below rather than raw useContext at each call site, so
// swapping the backing implementation later stays a change inside this one
// file. SessionContext itself is still exported (not just the hook) purely
// for RequireAuth.tsx — the one place that actually provides a value into
// it — to build its <SessionContext.Provider> with; no component wrapper is
// defined here for that so this stays a plain .ts file (a component export
// living alongside useSession would trip
// react-refresh/only-export-components).
export const SessionContext = createContext<CognitoUserSession | null>(null);

// Only ever rendered under RequireAuth (see components/RequireAuth.tsx),
// which doesn't render its children until a real session exists — so a
// null read here means a call site was rendered outside that guard, which
// is itself the bug worth surfacing loudly rather than quietly returning
// an optional value every consumer would then have to re-check.
export function useSession(): CognitoUserSession {
  const session = useContext(SessionContext);
  if (!session) {
    throw new Error('useSession must be used within RequireAuth');
  }
  return session;
}
