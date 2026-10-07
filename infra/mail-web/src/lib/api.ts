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
  attachments?: ReplyAttachment[],
): Promise<{ messageId: string }> {
  const res = await fetch(`${API_URL}/reply`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${session.getIdToken().getJwtToken()}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ address, key, body, attachments }),
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

export interface ReplyAttachment {
  key: string;
  filename: string;
  contentType: string;
}

interface PresignedPost {
  key: string;
  url: string;
  fields: Record<string, string>;
}

// Asks our backend for an S3 presigned POST for one outgoing attachment;
// the file bytes themselves go straight to S3 via uploadAttachment below.
export async function requestAttachmentUpload(
  session: CognitoUserSession,
  address: string,
  file: File,
): Promise<PresignedPost> {
  const res = await fetch(`${API_URL}/attachments`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${session.getIdToken().getJwtToken()}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      address,
      filename: file.name,
      contentType: file.type || 'application/octet-stream',
      size: file.size,
    }),
  });

  if (!res.ok) {
    const { error } = await res
      .json()
      .catch(() => ({ error: `Request failed (${res.status})` }));
    throw new Error(error);
  }

  return res.json();
}

// S3 rejects a presigned POST whose `file` field isn't last, and the request
// must not carry an Authorization header — the signature is in `fields`.
export async function uploadAttachment(
  post: PresignedPost,
  file: File,
): Promise<void> {
  const form = new FormData();
  Object.entries(post.fields).forEach(([name, value]) =>
    form.append(name, value),
  );
  form.append('Content-Type', file.type || 'application/octet-stream');
  form.append('file', file);

  const res = await fetch(post.url, { method: 'POST', body: form });

  if (res.status !== 204) {
    throw new Error(`Couldn't upload ${file.name}`);
  }
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
