import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  S3Client,
} from '@aws-sdk/client-s3';
import { SendEmailCommand, SESv2Client } from '@aws-sdk/client-sesv2';
import PostalMime from 'postal-mime';
import { inboxPrefix } from '../../../lib/mail/inbox.js';
import {
  MAX_ATTACHMENT_BYTES,
  MAX_FILENAME_LENGTH,
} from '../shared/attachmentLimits.js';
import { buildRawMessage, type OutgoingAttachment } from './buildRawMessage.js';

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
const ses = new SESv2Client({});

const MAIL_BUCKET_NAME = process.env.MAIL_BUCKET_NAME ?? '';
const ATTACHMENT_BUCKET_NAME = process.env.ATTACHMENT_BUCKET_NAME ?? '';
const MAX_ATTACHMENTS = 10;
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

interface AttachmentRef {
  key: string;
  filename: string;
  contentType: string;
}

interface ReplyRequestBody {
  address: string;
  key: string;
  body: string;
  attachments: AttachmentRef[];
}

function parseAttachments(value: unknown): AttachmentRef[] | null {
  if (value === undefined) {
    return [];
  }
  if (!Array.isArray(value) || value.length > MAX_ATTACHMENTS) {
    return null;
  }
  const refs: AttachmentRef[] = [];
  for (const item of value as unknown[]) {
    if (typeof item !== 'object' || item === null) {
      return null;
    }
    const { key, filename, contentType } = item as Record<string, unknown>;
    if (
      typeof key !== 'string' ||
      typeof filename !== 'string' ||
      typeof contentType !== 'string' ||
      filename.length > MAX_FILENAME_LENGTH
    ) {
      return null;
    }
    refs.push({ key, filename, contentType });
  }
  return refs;
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
  const attachments = parseAttachments(
    (parsed as Record<string, unknown>).attachments,
  );
  if (!attachments) {
    return null;
  }
  const { address, key, body } = parsed as Record<string, string>;
  return { address, key, body, attachments };
}

async function totalAttachmentSize(
  attachments: AttachmentRef[],
): Promise<number | { missing: string }> {
  let total = 0;
  for (const attachment of attachments) {
    try {
      const head = await s3.send(
        new HeadObjectCommand({
          Bucket: ATTACHMENT_BUCKET_NAME,
          Key: attachment.key,
        }),
      );
      total += head.ContentLength ?? 0;
    } catch {
      // Without s3:ListBucket a missing key is a 403, not a 404, so any
      // HeadObject failure is reported as not found.
      return { missing: attachment.filename };
    }
  }
  return total;
}

async function fetchAttachments(
  attachments: AttachmentRef[],
): Promise<OutgoingAttachment[]> {
  return Promise.all(
    attachments.map(async ({ key, filename, contentType }) => {
      const result = await s3.send(
        new GetObjectCommand({ Bucket: ATTACHMENT_BUCKET_NAME, Key: key }),
      );
      if (!result.Body) {
        throw new Error(`Attachment not found: ${filename}`);
      }
      return {
        filename,
        contentType,
        data: await result.Body.transformToByteArray(),
      };
    }),
  );
}

async function deleteAttachments(attachments: AttachmentRef[]): Promise<void> {
  const results = await Promise.allSettled(
    attachments.map(({ key }) =>
      s3.send(
        new DeleteObjectCommand({ Bucket: ATTACHMENT_BUCKET_NAME, Key: key }),
      ),
    ),
  );
  results.forEach((result, i) => {
    if (result.status === 'rejected') {
      console.error(
        `Failed to delete attachment ${attachments[i].key}`,
        result.reason,
      );
    }
  });
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
  const { address, key, body, attachments } = requestBody;

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
  if (body.trim() === '' && attachments.length === 0) {
    return jsonResponse(400, {
      error: 'Reply must have a body or at least one attachment',
    });
  }
  if (attachments.some((a) => !a.key.startsWith(`${address}/`))) {
    return jsonResponse(400, {
      error: `attachment key does not belong to ${address}`,
    });
  }

  if (attachments.length > 0) {
    const total = await totalAttachmentSize(attachments);
    if (typeof total !== 'number') {
      return jsonResponse(400, {
        error: `Attachment not found: ${total.missing}`,
      });
    }
    if (total > MAX_ATTACHMENT_BYTES) {
      return jsonResponse(413, { error: 'Attachments exceed 25 MiB in total' });
    }
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

  let outgoing: OutgoingAttachment[];
  try {
    outgoing = await fetchAttachments(attachments);
  } catch (err) {
    return jsonResponse(400, {
      error: err instanceof Error ? err.message : 'Attachment not found',
    });
  }
  // The object can be replaced between HeadObject and GetObject.
  const downloaded = outgoing.reduce((sum, f) => sum + f.data.byteLength, 0);
  if (downloaded > MAX_ATTACHMENT_BYTES) {
    return jsonResponse(413, { error: 'Attachments exceed 25 MiB in total' });
  }

  let raw: Uint8Array;
  let to: string;
  try {
    ({ raw, to } = buildRawMessage(
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
      outgoing,
    ));
  } catch (err) {
    return jsonResponse(400, {
      error:
        err instanceof Error ? err.message : 'Failed to build reply message',
    });
  }

  try {
    const sendResult = await ses.send(
      new SendEmailCommand({
        // FromEmailAddress must be set explicitly here (not inferred from
        // the raw message's From: header) for the ses:FromAddress IAM
        // condition on this Lambda's role to evaluate deterministically.
        FromEmailAddress: address,
        Destination: { ToAddresses: [to] },
        Content: { Raw: { Data: raw } },
      }),
    );
    await deleteAttachments(attachments);
    return jsonResponse(200, { messageId: sendResult.MessageId });
  } catch (err) {
    return jsonResponse(502, {
      error: err instanceof Error ? err.message : 'Failed to send reply',
    });
  }
}
