import { DeleteObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { inboxPrefix } from '../../../lib/mail/inbox.js';

// A minimal local shape of the pieces of an API Gateway v2 HTTP API
// proxy event/result this handler actually touches — avoids pulling in
// @types/aws-lambda as a new dependency just for two field names. Same
// shape as reply/index.ts's own local declaration.
interface HttpApiEvent {
  body?: string;
}

interface HttpApiResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

const s3 = new S3Client({});

const MAIL_BUCKET_NAME = process.env.MAIL_BUCKET_NAME ?? '';
const MAILBOX_ADDRESSES = (process.env.MAILBOX_ADDRESSES ?? '')
  .split(',')
  .map((address) => address.trim())
  .filter(Boolean);

function jsonResponse(
  statusCode: number,
  body: Record<string, unknown>,
): HttpApiResult {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  };
}

interface DeleteRequestBody {
  address: string;
  key: string;
}

function parseRequestBody(
  rawBody: string | undefined,
): DeleteRequestBody | null {
  if (!rawBody) {
    return null;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return null;
  }
  if (
    typeof parsed !== 'object' ||
    parsed === null ||
    typeof (parsed as Record<string, unknown>).address !== 'string' ||
    typeof (parsed as Record<string, unknown>).key !== 'string'
  ) {
    return null;
  }
  return parsed as DeleteRequestBody;
}

// API Gateway has already validated the caller's JWT via the
// HttpUserPoolAuthorizer before this handler is ever invoked — no token
// re-verification needed here.
export async function handler(event: HttpApiEvent): Promise<HttpApiResult> {
  const requestBody = parseRequestBody(event.body);
  if (!requestBody) {
    return jsonResponse(400, {
      error: 'Request body must be { address, key }',
    });
  }
  const { address, key } = requestBody;

  // Fail-fast defense-in-depth: the real security boundary is the IAM
  // resource-scoped s3:DeleteObject grant on this Lambda's role either
  // way, but that's not a reason to skip validating the request shape here
  // too.
  if (!MAILBOX_ADDRESSES.includes(address)) {
    return jsonResponse(400, { error: `Unknown mailbox address: ${address}` });
  }
  if (!key.startsWith(inboxPrefix(address))) {
    return jsonResponse(400, {
      error: `key does not belong to ${address}'s inbox`,
    });
  }

  try {
    // S3's DeleteObject is idempotent — deleting an already-gone key still
    // succeeds with no error — so no existence check before deleting; that's
    // correct DELETE behavior, not a gap.
    await s3.send(
      new DeleteObjectCommand({ Bucket: MAIL_BUCKET_NAME, Key: key }),
    );
    return jsonResponse(200, { success: true });
  } catch (err) {
    return jsonResponse(502, {
      error: err instanceof Error ? err.message : 'Failed to delete message',
    });
  }
}
