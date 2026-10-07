import { S3Client } from '@aws-sdk/client-s3';
import { createPresignedPost } from '@aws-sdk/s3-presigned-post';
import { randomUUID } from 'node:crypto';
import {
  MAX_ATTACHMENT_BYTES,
  MAX_FILENAME_LENGTH,
} from '../shared/attachmentLimits.js';
import { sanitizeContentType } from '../reply/buildRawMessage.js';

// Same minimal local event/result shapes as reply/index.ts.
interface HttpApiEvent {
  body?: string;
}

interface HttpApiResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

const s3 = new S3Client({});

const ATTACHMENT_BUCKET_NAME = process.env.ATTACHMENT_BUCKET_NAME ?? '';
const MAILBOX_ADDRESSES = (process.env.MAILBOX_ADDRESSES ?? '')
  .split(',')
  .map((address) => address.trim())
  .filter(Boolean);

const UPLOAD_EXPIRES_SECONDS = 15 * 60;

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

interface AttachmentRequestBody {
  address: string;
  filename: string;
  contentType: string;
  size: number;
}

function parseRequestBody(
  rawBody: string | undefined,
): AttachmentRequestBody | null {
  if (!rawBody) {
    return null;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null) {
    return null;
  }
  const { address, filename, contentType, size } = parsed as Record<
    string,
    unknown
  >;
  if (
    typeof address !== 'string' ||
    typeof filename !== 'string' ||
    typeof contentType !== 'string' ||
    typeof size !== 'number'
  ) {
    return null;
  }
  return { address, filename, contentType, size };
}

// API Gateway has already validated the caller's JWT. The presigned POST is
// pinned to one random key under the caller's mailbox address, a size range
// and a Content-Type, so the browser can upload exactly one object and
// nothing else.
export async function handler(event: HttpApiEvent): Promise<HttpApiResult> {
  const requestBody = parseRequestBody(event.body);
  if (!requestBody) {
    return jsonResponse(400, {
      error: 'Request body must be { address, filename, contentType, size }',
    });
  }
  const { address, filename, contentType, size } = requestBody;

  if (!MAILBOX_ADDRESSES.includes(address)) {
    return jsonResponse(400, { error: `Unknown mailbox address: ${address}` });
  }
  if (filename.length === 0 || filename.length > MAX_FILENAME_LENGTH) {
    return jsonResponse(400, {
      error: `filename must be 1..${MAX_FILENAME_LENGTH} characters`,
    });
  }
  if (!Number.isInteger(size) || size < 1 || size > MAX_ATTACHMENT_BYTES) {
    return jsonResponse(400, {
      error: `size must be an integer between 1 and ${MAX_ATTACHMENT_BYTES} bytes`,
    });
  }

  const key = `${address}/${randomUUID()}`;
  try {
    const { url, fields } = await createPresignedPost(s3, {
      Bucket: ATTACHMENT_BUCKET_NAME,
      Key: key,
      Conditions: [['content-length-range', 1, MAX_ATTACHMENT_BYTES]],
      Fields: { 'Content-Type': sanitizeContentType(contentType) },
      Expires: UPLOAD_EXPIRES_SECONDS,
    });
    return jsonResponse(200, { key, url, fields });
  } catch (err) {
    return jsonResponse(502, {
      error: err instanceof Error ? err.message : 'Failed to create upload URL',
    });
  }
}
