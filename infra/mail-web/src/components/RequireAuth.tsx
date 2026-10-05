import { useEffect, useState, type ReactNode } from 'react';
import { Navigate } from 'react-router-dom';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';
import { getCurrentSession } from '../lib/auth';
import { SessionContext } from '../lib/session';

type Status =
  | { kind: 'loading' }
  | { kind: 'authenticated'; session: CognitoUserSession }
  | { kind: 'unauthenticated' };

// Route-guard wrapper: checks the session and redirects if absent
// (App.tsx wraps every route except
// /login with this as a pathless layout route). Also the one place that
// resolves the actual CognitoUserSession (not just its ID token, unlike
// useIdToken) and hands it down via SessionProvider, since s3Client.ts
// needs the full session to federate AWS credentials.
export default function RequireAuth({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<Status>({ kind: 'loading' });

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const session = await getCurrentSession();
      if (cancelled) return;
      setStatus(
        session
          ? { kind: 'authenticated', session }
          : { kind: 'unauthenticated' },
      );
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  if (status.kind === 'loading') {
    return (
      <div role="status" aria-live="polite" className="p-8 text-center">
        Loading…
      </div>
    );
  }
  if (status.kind === 'unauthenticated') {
    return <Navigate to="/login" replace />;
  }
  return (
    <SessionContext.Provider value={status.session}>
      {children}
    </SessionContext.Provider>
  );
}
