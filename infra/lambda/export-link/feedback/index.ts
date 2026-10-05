import {
  FeedbackRequest,
  FeedbackResponse,
} from '../../../lib/export-link/schemas.js';
import { authenticateSigned } from '../shared/auth.js';
import { lazyHandler, type Deps, type Handler } from '../shared/deps.js';
import {
  ApiError,
  jsonResponse,
  type HttpApiEvent,
  toErrorResponse,
} from '../shared/http.js';

export const FEEDBACK_PER_DAY = 3;
export const FEEDBACK_RATE_SCOPE = 'feedback';
const RATE_RECORD_TTL_SECONDS = 2 * 24 * 60 * 60;

const SUBJECTS = { feature: '[Feature] Feedback', bug: '[Bug] Feedback' };

export function createHandler(deps: Deps): Handler {
  async function send(event: HttpApiEvent) {
    const { device, request } = await authenticateSigned(
      deps,
      event,
      FeedbackRequest,
    );
    const now = Math.floor(deps.nowMs() / 1000);

    const day = new Date(now * 1000).toISOString().slice(0, 10);
    const sentToday = await deps.store.getRate(
      device.keyId,
      day,
      FEEDBACK_RATE_SCOPE,
    );
    if (sentToday >= FEEDBACK_PER_DAY) {
      throw new ApiError('rate_limited', 'Too much feedback sent today');
    }

    // Diagnostics come first so the free-form message can't forge them.
    const text = [
      `Kind: ${request.kind}`,
      `App version: ${request.appVersion}`,
      `OS version: ${request.osVersion}`,
      `Device model: ${request.deviceModel}`,
      `Device: ${device.keyId.slice(0, 8)}`,
      `Sent: ${new Date(now * 1000).toISOString()}`,
      '',
      '-- Message --',
      request.message,
    ].join('\n');
    await deps.mailer.send({
      from: deps.feedbackFrom,
      to: deps.feedbackTo,
      replyTo: request.email,
      subject: SUBJECTS[request.kind],
      text,
    });
    // Only a delivered mail spends a slot. Concurrent requests can race past
    // the check above and briefly exceed the limit; the mail already went, so
    // neither a lost nor a failed increment is an error.
    try {
      await deps.store.incrementRate(
        device.keyId,
        day,
        FEEDBACK_PER_DAY,
        now + RATE_RECORD_TTL_SECONDS,
        FEEDBACK_RATE_SCOPE,
      );
    } catch (err) {
      console.error(
        'feedback rate increment failed',
        err instanceof Error ? err.name : 'unknown',
      );
    }
    return jsonResponse(200, FeedbackResponse.parse({ sent: true }));
  }

  return async (event) => {
    try {
      switch (event.routeKey) {
        case 'POST /api/v1/feedback':
          return await send(event);
        default:
          throw new ApiError('not_found', 'Unknown route');
      }
    } catch (err) {
      return toErrorResponse(err);
    }
  };
}

export const handler = lazyHandler(createHandler);
