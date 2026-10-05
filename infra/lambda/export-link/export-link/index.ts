import {
  CompleteExportLinkRequest,
  CompleteExportLinkResponse,
  CreateExportLinkRequest,
  CreateExportLinkResponse,
  CurrentExportLinkRequest,
  CurrentExportLinkResponse,
  EXPORT_LINK_TTL_SECONDS,
  RevokeExportLinkRequest,
  RevokeExportLinkResponse,
  type ExportLinkRecord,
} from '../../../lib/export-link/schemas.js';
import { authenticateSigned } from '../shared/auth.js';
import { lazyHandler, type Deps, type Handler } from '../shared/deps.js';
import {
  ApiError,
  deadLinkError,
  iso,
  jsonResponse,
  type HttpApiEvent,
  toErrorResponse,
} from '../shared/http.js';
import { objectKey } from '../shared/objects.js';

export const CREATES_PER_DAY = 10;
export const UPLOAD_WINDOW_SECONDS = 10 * 60;
const RATE_RECORD_TTL_SECONDS = 2 * 24 * 60 * 60;
const RECORD_RETENTION_SECONDS = 7 * 24 * 60 * 60;

export function createHandler(deps: Deps): Handler {
  const nowSeconds = () => Math.floor(deps.nowMs() / 1000);

  function summary(link: ExportLinkRecord) {
    if (link.status !== 'pending' && link.status !== 'ready') {
      throw new Error('summary of a link that is not open');
    }
    return {
      exportLinkId: link.exportLinkId,
      status: link.status,
      sizeBytes: link.sizeBytes,
      createdAt: iso(link.createdAt),
      expiresAt: iso(link.expiresAt),
    };
  }

  const isOpen = (link: ExportLinkRecord | null, now: number) =>
    link !== null &&
    (link.status === 'pending' || link.status === 'ready') &&
    link.expiresAt > now;

  async function revokeOwned(link: ExportLinkRecord, keyId: string) {
    const now = nowSeconds();
    const revoked = await deps.store.revokeLink(link.exportLinkId, keyId, now);
    if (revoked) {
      // The record stays in the sweep index (due now) until the object is
      // really gone, so a failed delete here is retried by the sweeper.
      await deps.objects.delete(objectKey(link.exportLinkId));
      await deps.store.settleSwept(link.exportLinkId, 'revoked', now);
    }
    return revoked;
  }

  async function create(event: HttpApiEvent) {
    const { device, request } = await authenticateSigned(
      deps,
      event,
      CreateExportLinkRequest,
    );
    const now = nowSeconds();

    const day = new Date(now * 1000).toISOString().slice(0, 10);
    const allowed = await deps.store.incrementRate(
      device.keyId,
      day,
      CREATES_PER_DAY,
      now + RATE_RECORD_TTL_SECONDS,
    );
    if (!allowed) {
      throw new ApiError('rate_limited', 'Too many export links today');
    }

    let replacedExportLinkId: string | null = null;
    if (device.currentExportLinkId) {
      const previous = await deps.store.getLink(device.currentExportLinkId);
      if (
        previous &&
        (previous.status === 'pending' || previous.status === 'ready') &&
        (await revokeOwned(previous, device.keyId))
      ) {
        replacedExportLinkId = previous.exportLinkId;
      }
    }

    const exportLinkId = deps.randomBytes(16).toString('base64url');
    const expiresAt = now + UPLOAD_WINDOW_SECONDS;
    await deps.store.putLink({
      pk: `EXPORT#${exportLinkId}`,
      exportLinkId,
      keyId: device.keyId,
      status: 'pending',
      sizeBytes: request.sizeBytes,
      sha256: request.sha256,
      createdAt: now,
      expiresAt,
      sweep: 'OPEN',
      sweepAt: expiresAt,
      ttl: expiresAt + RECORD_RETENTION_SECONDS,
    });
    await deps.store.setCurrentLink(device.keyId, exportLinkId);

    const upload = await deps.objects.presignPut(objectKey(exportLinkId), {
      sizeBytes: request.sizeBytes,
      sha256: request.sha256,
      expiresInSeconds: UPLOAD_WINDOW_SECONDS,
    });
    return jsonResponse(
      200,
      CreateExportLinkResponse.parse({
        exportLinkId,
        replacedExportLinkId,
        upload: {
          method: 'PUT',
          url: upload.url,
          headers: upload.headers,
          expiresAt: iso(expiresAt),
        },
      }),
    );
  }

  const completeResponse = (link: ExportLinkRecord) =>
    jsonResponse(200, CompleteExportLinkResponse.parse(summary(link)));

  async function complete(event: HttpApiEvent) {
    const { device, request } = await authenticateSigned(
      deps,
      event,
      CompleteExportLinkRequest,
    );
    const now = nowSeconds();

    const link = await deps.store.getLink(request.exportLinkId);
    if (!link || link.keyId !== device.keyId) {
      throw new ApiError('not_found', 'Unknown export link');
    }
    if (link.expiresAt <= now)
      throw new ApiError('expired', 'Export link expired');
    // A retry after a lost response: report the already-ready link as is.
    if (link.status === 'ready') return completeResponse(link);
    if (link.status !== 'pending') throw deadLinkError(link);

    const key = objectKey(link.exportLinkId);
    const stored = await deps.objects.head(key);
    if (
      !stored ||
      stored.sizeBytes !== link.sizeBytes ||
      stored.sha256 !== link.sha256
    ) {
      await deps.objects.delete(key);
      throw new ApiError(
        'upload_mismatch',
        'Uploaded object does not match the declared size and checksum',
      );
    }

    const expiresAt = now + EXPORT_LINK_TTL_SECONDS;
    const ready = await deps.store.markReady(
      link.exportLinkId,
      device.keyId,
      now,
      expiresAt,
      expiresAt + RECORD_RETENTION_SECONDS,
    );
    if (!ready) {
      const latest = await deps.store.getLink(link.exportLinkId);
      if (latest?.status === 'ready' && latest.expiresAt > now) {
        return completeResponse(latest);
      }
      throw deadLinkError(latest);
    }
    return completeResponse(ready);
  }

  async function current(event: HttpApiEvent) {
    const { device } = await authenticateSigned(
      deps,
      event,
      CurrentExportLinkRequest,
    );
    const link = device.currentExportLinkId
      ? await deps.store.getLink(device.currentExportLinkId)
      : null;
    const exportLink =
      link && link.keyId === device.keyId && isOpen(link, nowSeconds())
        ? summary(link)
        : null;
    return jsonResponse(200, CurrentExportLinkResponse.parse({ exportLink }));
  }

  async function revoke(event: HttpApiEvent) {
    const { device, request } = await authenticateSigned(
      deps,
      event,
      RevokeExportLinkRequest,
    );
    const link = await deps.store.getLink(request.exportLinkId);
    if (!link || link.keyId !== device.keyId) {
      throw new ApiError('not_found', 'Unknown export link');
    }
    if (!(await revokeOwned(link, device.keyId))) {
      const latest = await deps.store.getLink(link.exportLinkId);
      if (latest?.status !== 'revoked') throw deadLinkError(latest);
    }
    return jsonResponse(200, RevokeExportLinkResponse.parse({ revoked: true }));
  }

  return async (event) => {
    try {
      switch (event.routeKey) {
        case 'POST /api/v1/export-links':
          return await create(event);
        case 'POST /api/v1/export-links/complete':
          return await complete(event);
        case 'POST /api/v1/export-links/current':
          return await current(event);
        case 'POST /api/v1/export-links/revoke':
          return await revoke(event);
        default:
          throw new ApiError('not_found', 'Unknown route');
      }
    } catch (err) {
      return toErrorResponse(err);
    }
  };
}

export const handler = lazyHandler(createHandler);
