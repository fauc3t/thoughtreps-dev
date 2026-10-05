import type { CognitoUserSession } from 'amazon-cognito-identity-js';
import { API_URL } from './config';

// Unlike credentials.ts (which federates the ID token into AWS credentials
// for direct S3 access), this call goes to our own backend, which validates
// the ID token itself via a Cognito JWT authorizer — so the token is sent
// as-is, as a Bearer header, not federated. Same `getIdToken().getJwtToken()`
// call as credentials.ts, reused rather than re-derived.
export async function replyToMessage(
  session: CognitoUserSession,
  address: string,
  key: string,
  body: string,
): Promise<{ messageId: string }> {
  const res = await fetch(`${API_URL}/reply`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${session.getIdToken().getJwtToken()}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ address, key, body }),
  });

  if (!res.ok) {
    // The API contract promises a JSON `{ error }` body on every non-2xx
    // response, but a network edge case (a proxy/gateway timeout page, a
    // dropped connection mid-body) could still hand back something that
    // isn't valid JSON — fall back to a generic message keyed off the
    // status code instead of letting `res.json()` throw and mask the
    // original HTTP failure.
    const { error } = await res
      .json()
      .catch(() => ({ error: `Request failed (${res.status})` }));
    throw new Error(error);
  }

  return res.json();
}

// Same Bearer-ID-token-to-our-own-backend shape as replyToMessage above —
// deleting is a destructive, irreversible mutation, so like reply it goes
// through this authenticated API rather than the browser holding
// delete-capable S3 credentials directly.
export async function deleteMessage(
  session: CognitoUserSession,
  address: string,
  key: string,
): Promise<{ success: true }> {
  const res = await fetch(`${API_URL}/delete`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${session.getIdToken().getJwtToken()}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ address, key }),
  });

  if (!res.ok) {
    const { error } = await res
      .json()
      .catch(() => ({ error: `Request failed (${res.status})` }));
    throw new Error(error);
  }

  return res.json();
}
