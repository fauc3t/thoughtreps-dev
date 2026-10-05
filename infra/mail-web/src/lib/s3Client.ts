import { S3Client } from '@aws-sdk/client-s3';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';
import { AWS_REGION } from './config';
import { credentialsFromSession } from './credentials';

// Credentials are tied to a specific session (they're federated from that
// session's own ID token — see credentials.ts), so a signed-out/signed-back
// -in user needs a genuinely new client, not an existing one mutated in
// place. Memoized by the session's own ID token string rather than by
// object identity, since getCurrentSession() can resolve a fresh
// CognitoUserSession object on every call even when it's really still the
// same underlying session (a refreshed-in-place token would already be a
// new session's worth of credentials scope, so keying on the token itself
// is also the more correct invalidation signal, not just a convenience).
let cachedClient: S3Client | null = null;
let cachedTokenKey: string | null = null;

export function getS3Client(session: CognitoUserSession): S3Client {
  const tokenKey = session.getIdToken().getJwtToken();
  if (!cachedClient || cachedTokenKey !== tokenKey) {
    cachedClient = new S3Client({
      region: AWS_REGION,
      credentials: credentialsFromSession(session),
    });
    cachedTokenKey = tokenKey;
  }
  return cachedClient;
}
