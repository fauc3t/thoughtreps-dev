import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { SendRawEmailCommand, SESClient } from '@aws-sdk/client-ses';
import PostalMime from 'postal-mime';
import { inboxPrefix } from '../../../lib/mail/inbox.js';
import { buildRawMessage } from './buildRawMessage.js';

// A minimal local shape of the pieces of an API Gateway v2 HTTP API
// proxy event/result this handler actually touches — avoids pulling in
// @types/aws-lambda as a new dependency just for two field names.
interface HttpApiEvent {
  body?: string;
}

interface HttpApiResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

const s3 = new S3Client({});
const ses = new SESClient({});

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

interface ReplyRequestBody {
  address: string;
  key: string;
  body: string;
}

function parseRequestBody(
  rawBody: string | undefined,
): ReplyRequestBody | null {
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
    typeof (parsed as Record<string, unknown>).key !== 'string' ||
    typeof (parsed as Record<string, unknown>).body !== 'string'
  ) {
    return null;
  }
  return parsed as ReplyRequestBody;
}

// API Gateway has already validated the caller's JWT via the
// HttpUserPoolAuthorizer before this handler is ever invoked — no token
// re-verification needed here.
export async function handler(event: HttpApiEvent): Promise<HttpApiResult> {
  const requestBody = parseRequestBody(event.body);
  if (!requestBody) {
    return jsonResponse(400, {
      error: 'Request body must be { address, key, body }',
    });
  }
  const { address, key, body } = requestBody;

  // Fail-fast defense-in-depth: the real security boundary is the IAM
  // ses:FromAddress condition on this Lambda's SendRawEmail grant either
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

  let originalRaw: Uint8Array;
  try {
    const getResult = await s3.send(
      new GetObjectCommand({ Bucket: MAIL_BUCKET_NAME, Key: key }),
    );
    if (!getResult.Body) {
      return jsonResponse(404, { error: `Original message not found: ${key}` });
    }
    originalRaw = await getResult.Body.transformToByteArray();
  } catch {
    return jsonResponse(404, { error: `Original message not found: ${key}` });
  }

  let original: Awaited<ReturnType<typeof PostalMime.parse>>;
  try {
    original = await PostalMime.parse(originalRaw);
  } catch {
    return jsonResponse(400, {
      error: `Original message could not be parsed: ${key}`,
    });
  }

  let raw: Uint8Array;
  try {
    ({ raw } = buildRawMessage(
      {
        messageId: original.messageId ?? null,
        references: original.references ?? null,
        subject: original.subject ?? null,
        // postal-mime's Address type also covers a group-address shape
        // (`{ name, group }`, no `address` field) — narrow it down to the
        // { address, name } shape buildRawMessage expects, treating a group
        // From (a technically-legal but exceedingly rare header shape) the
        // same as "no address" rather than trying to reply to a group.
        from: original.from
          ? {
              address: original.from.address ?? null,
              name: original.from.name ?? null,
            }
          : null,
      },
      body,
      address,
    ));
  } catch (err) {
    return jsonResponse(400, {
      error:
        err instanceof Error ? err.message : 'Failed to build reply message',
    });
  }

  try {
    const sendResult = await ses.send(
      new SendRawEmailCommand({
        // Source must be set explicitly here (not inferred from the raw
        // message's From: header) for the ses:FromAddress IAM condition on
        // this Lambda's role to evaluate deterministically.
        Source: address,
        RawMessage: { Data: raw },
      }),
    );
    return jsonResponse(200, { messageId: sendResult.MessageId });
  } catch (err) {
    return jsonResponse(502, {
      error: err instanceof Error ? err.message : 'Failed to send reply',
    });
  }
}
