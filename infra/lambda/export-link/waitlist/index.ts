import {
  WaitlistRequest,
  WaitlistResponse,
} from '../../../lib/export-link/schemas.js';
import { lazyHandler, type Deps, type Handler } from '../shared/deps.js';
import {
  ApiError,
  jsonResponse,
  parseBody,
  type HttpApiEvent,
  toErrorResponse,
} from '../shared/http.js';

const SUBJECT = '[Waitlist] New signup';

const stripLineBreaks = (value: string) => value.replace(/[\r\n]/g, ' ');

export function createHandler(deps: Deps): Handler {
  async function signUp(event: HttpApiEvent) {
    if (
      !/^application\/json\s*(;|$)/i.test(event.headers?.['content-type'] ?? '')
    ) {
      throw new ApiError(
        'bad_request',
        'Content-Type must be application/json',
      );
    }
    const request = parseBody(event, WaitlistRequest);
    const ok = () => jsonResponse(200, WaitlistResponse.parse({ ok: true }));
    if (request.honeypot !== '') return ok();

    const nowSeconds = Math.floor(deps.nowMs() / 1000);
    const createdAt = new Date(nowSeconds * 1000).toISOString();
    const isNew = await deps.waitlist.signUp(
      request.email,
      request.beta,
      createdAt,
    );
    if (!isNew) return ok();

    try {
      await deps.mailer.send({
        from: deps.waitlistFrom,
        to: deps.feedbackTo,
        subject: SUBJECT,
        text: [
          `Email: ${stripLineBreaks(request.email)}`,
          `Beta: ${request.beta ? 'yes' : 'no'}`,
          `Signed up: ${createdAt}`,
        ].join('\n'),
      });
    } catch (err) {
      console.error(
        'waitlist notification failed',
        err instanceof Error ? err.name : 'unknown',
      );
    }
    return ok();
  }

  return async (event) => {
    try {
      switch (event.routeKey) {
        case 'POST /api/v1/waitlist':
          return await signUp(event);
        default:
          throw new ApiError('not_found', 'Unknown route');
      }
    } catch (err) {
      return toErrorResponse(err);
    }
  };
}

export const handler = lazyHandler(createHandler);
