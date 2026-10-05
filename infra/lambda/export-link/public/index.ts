import {
  ClaimExportLinkResponse,
  ExportLinkId,
  ExportLinkStatusResponse,
  type ExportLinkRecord,
} from '../../../lib/export-link/schemas.js';
import { lazyHandler, type Deps, type Handler } from '../shared/deps.js';
import {
  ApiError,
  emptyResponse,
  iso,
  jsonResponse,
  parsePathId,
  toErrorResponse,
  type HttpApiEvent,
} from '../shared/http.js';
import { objectKey } from '../shared/objects.js';

export const DOWNLOAD_URL_SECONDS = 5 * 60;
// A claimed object that never gets a /done (closed tab, failed download) is
// still deleted shortly after the download URL itself stops working.
export const CLAIMED_OBJECT_GRACE_SECONDS = 10 * 60;

type PublicStatus = 'ready' | 'used' | 'expired' | 'revoked';

// Reports `expired` for a ready link past its expiry even before the sweeper
// has recorded it. Pending links are not visible: the owner hasn't finished
// uploading.
function publicStatus(
  link: ExportLinkRecord | null,
  now: number,
): PublicStatus | null {
  if (!link || link.status === 'pending') return null;
  if (link.status === 'ready' && link.expiresAt <= now) return 'expired';
  return link.status;
}

export function createHandler(deps: Deps): Handler {
  const nowSeconds = () => Math.floor(deps.nowMs() / 1000);

  // Read-only on purpose: link-preview bots and prefetchers issue GETs, and
  // they must not be able to consume the single-use link.
  async function status(event: HttpApiEvent) {
    const id = parsePathId(event, ExportLinkId);
    const link = await deps.store.getLink(id);
    const state = publicStatus(link, nowSeconds());
    if (!link || !state) throw new ApiError('not_found', 'Unknown export link');
    return jsonResponse(
      200,
      ExportLinkStatusResponse.parse(
        state === 'ready'
          ? {
              status: state,
              sizeBytes: link.sizeBytes,
              expiresAt: iso(link.expiresAt),
            }
          : { status: state },
      ),
    );
  }

  async function claim(event: HttpApiEvent) {
    const id = parsePathId(event, ExportLinkId);
    const now = nowSeconds();
    const claimed = await deps.store.claimLink(
      id,
      now,
      now + CLAIMED_OBJECT_GRACE_SECONDS,
    );
    if (!claimed) {
      const state = publicStatus(await deps.store.getLink(id), now);
      if (state === null)
        throw new ApiError('not_found', 'Unknown export link');
      throw new ApiError(
        state === 'ready' ? 'expired' : state,
        `Export link is ${state}`,
      );
    }
    const url = await deps.objects.presignGet(
      objectKey(id),
      DOWNLOAD_URL_SECONDS,
    );
    return jsonResponse(
      200,
      ClaimExportLinkResponse.parse({
        download: { url, expiresAt: iso(now + DOWNLOAD_URL_SECONDS) },
        sizeBytes: claimed.sizeBytes,
        sha256: claimed.sha256,
      }),
    );
  }

  async function done(event: HttpApiEvent) {
    const id = parsePathId(event, ExportLinkId);
    const link = await deps.store.getLink(id);
    if (link?.status === 'used') {
      await deps.objects.delete(objectKey(id));
      await deps.store.finishUsed(id, nowSeconds());
    }
    return emptyResponse(204);
  }

  return async (event) => {
    try {
      switch (event.routeKey) {
        case 'GET /api/v1/export-links/{id}':
          return await status(event);
        case 'POST /api/v1/export-links/{id}/claim':
          return await claim(event);
        case 'POST /api/v1/export-links/{id}/done':
          return await done(event);
        default:
          throw new ApiError('not_found', 'Unknown route');
      }
    } catch (err) {
      return toErrorResponse(err);
    }
  };
}

export const handler = lazyHandler(createHandler);
