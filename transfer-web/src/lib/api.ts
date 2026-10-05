import {
  ClaimExportLinkResponse,
  ErrorResponse,
  ExportLinkStatusResponse,
} from '@thoughtreps/infra/export-link/schemas';
import type { z } from 'zod';

export type ApiFailureKind =
  | 'not_found'
  | 'used'
  | 'expired'
  | 'revoked'
  | 'network'
  | 'unexpected';

export class ApiFailure extends Error {
  constructor(readonly kind: ApiFailureKind) {
    super(kind);
  }
}

export type LinkStatus = z.infer<typeof ExportLinkStatusResponse>;
export type Claim = z.infer<typeof ClaimExportLinkResponse>;

const endpoint = (id: string, suffix = '') =>
  `/api/v1/export-links/${id}${suffix}`;

async function request<T extends z.ZodType>(
  path: string,
  method: 'GET' | 'POST',
  schema: T,
  signal?: AbortSignal,
): Promise<z.infer<T>> {
  let response: Response;
  try {
    response = await fetch(path, { method, signal });
  } catch {
    throw new ApiFailure('network');
  }
  const body: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    const error = ErrorResponse.safeParse(body);
    const code = error.success ? error.data.error : null;
    if (
      code === 'not_found' ||
      code === 'used' ||
      code === 'expired' ||
      code === 'revoked'
    ) {
      throw new ApiFailure(code);
    }
    throw new ApiFailure('unexpected');
  }
  const parsed = schema.safeParse(body);
  if (!parsed.success) throw new ApiFailure('unexpected');
  return parsed.data;
}

export const getStatus = (id: string, signal?: AbortSignal) =>
  request(endpoint(id), 'GET', ExportLinkStatusResponse, signal);

export const claimLink = (id: string) =>
  request(endpoint(id, '/claim'), 'POST', ClaimExportLinkResponse);

export async function markDone(id: string): Promise<void> {
  try {
    await fetch(endpoint(id, '/done'), { method: 'POST' });
  } catch {
    // The server sweep deletes the object if this never arrives.
  }
}
