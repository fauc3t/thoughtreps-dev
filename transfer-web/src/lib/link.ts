import { ExportLinkId } from '@thoughtreps/infra/export-link/schemas';

const KEY_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export type ParsedLink =
  | { ok: true; id: string; key: string }
  | { ok: false; reason: 'bad_id' | 'bad_key' };

export function parseLink(pathname: string, hash: string): ParsedLink {
  const id = /^\/x\/([^/]+)\/?$/.exec(pathname)?.[1] ?? '';
  if (!ExportLinkId.safeParse(id).success) return { ok: false, reason: 'bad_id' };
  const key = hash.startsWith('#') ? hash.slice(1) : hash;
  if (!KEY_PATTERN.test(key)) return { ok: false, reason: 'bad_key' };
  return { ok: true, id, key };
}
