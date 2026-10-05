import type { z } from 'zod';
import {
  ErrorCode,
  type ExportLinkRecord,
} from '../../../lib/export-link/schemas.js';

type ErrorCodeName = z.infer<typeof ErrorCode>;

// A minimal local shape of the API Gateway v2 HTTP API proxy event/result
// pieces these handlers touch (same approach as lambda/mail/delete).
export interface HttpApiEvent {
  routeKey: string;
  headers?: Record<string, string | undefined>;
  pathParameters?: Record<string, string | undefined>;
  body?: string;
  isBase64Encoded?: boolean;
}

export interface HttpApiResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
}

const STATUS: Record<ErrorCodeName, number> = {
  bad_request: 400,
  attestation_invalid: 401,
  assertion_invalid: 401,
  challenge_invalid: 401,
  rate_limited: 429,
  too_large: 413,
  not_found: 404,
  upload_mismatch: 409,
  used: 410,
  expired: 410,
  revoked: 410,
};

export class ApiError extends Error {
  constructor(
    readonly code: ErrorCodeName,
    message: string,
  ) {
    super(message);
  }
}

// no-store everywhere: responses carry presigned URLs and per-link state,
// and the CloudFront /api/* behavior already disables caching.
export function jsonResponse(statusCode: number, body: unknown): HttpApiResult {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store',
    },
    body: JSON.stringify(body),
  };
}

export function emptyResponse(statusCode: number): HttpApiResult {
  return { statusCode, headers: { 'Cache-Control': 'no-store' }, body: '' };
}

export function errorResponse(err: ApiError): HttpApiResult {
  return jsonResponse(STATUS[err.code], {
    error: ErrorCode.parse(err.code),
    message: err.message,
  });
}

// Never logs the request, only the error's class, so bodies, assertions and
// identifiers stay out of CloudWatch.
export function toErrorResponse(err: unknown): HttpApiResult {
  if (err instanceof ApiError) return errorResponse(err);
  console.error('unhandled error', err instanceof Error ? err.name : 'unknown');
  return jsonResponse(500, { message: 'internal error' });
}

// The assertion signs a hash of the exact request bytes, so verification
// must see them before any JSON parsing or re-serialisation.
export function rawBody(event: HttpApiEvent): Buffer {
  if (!event.body) return Buffer.alloc(0);
  return Buffer.from(event.body, event.isBase64Encoded ? 'base64' : 'utf8');
}

export function parseBody<S extends z.ZodType>(
  event: HttpApiEvent,
  schema: S,
): z.infer<S> {
  let json: unknown;
  try {
    json = JSON.parse(rawBody(event).toString('utf8'));
  } catch {
    throw new ApiError('bad_request', 'Body must be JSON');
  }
  const parsed = schema.safeParse(json);
  if (parsed.success) return parsed.data;
  if (
    parsed.error.issues.some(
      (issue) => issue.code === 'too_big' && issue.path[0] === 'sizeBytes',
    )
  ) {
    throw new ApiError('too_large', 'Export exceeds the upload size limit');
  }
  throw new ApiError('bad_request', 'Invalid request body');
}

export function parsePathId<S extends z.ZodType<string>>(
  event: HttpApiEvent,
  schema: S,
): string {
  const parsed = schema.safeParse(event.pathParameters?.id);
  if (!parsed.success) throw new ApiError('bad_request', 'Invalid link id');
  return parsed.data;
}

// Maps a link that can no longer be acted on to its client-facing error.
// A pending link whose upload window has passed reads as expired.
export function deadLinkError(link: ExportLinkRecord | null): ApiError {
  if (!link) return new ApiError('not_found', 'Unknown export link');
  switch (link.status) {
    case 'used':
      return new ApiError('used', 'Export link was already used');
    case 'revoked':
      return new ApiError('revoked', 'Export link was revoked');
    case 'ready':
      return new ApiError('bad_request', 'Export link is already complete');
    default:
      return new ApiError('expired', 'Export link expired');
  }
}

export const iso = (epochSeconds: number) =>
  new Date(epochSeconds * 1000).toISOString();
