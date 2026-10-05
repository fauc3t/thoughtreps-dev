import type { z } from 'zod';
import {
  AssertionHeaders,
  type DeviceRecord,
} from '../../../lib/export-link/schemas.js';
import { AssertionError, verifyAssertion } from './appattest.js';
import type { Deps } from './deps.js';
import { ApiError, parseBody, rawBody, type HttpApiEvent } from './http.js';

// Order matters: the signature and counter are checked and the counter is
// advanced before the challenge is consumed, so a replayed request fails on
// the counter and never reaches (or wastes) a challenge.
export async function authenticateSigned<
  S extends z.ZodType<{ challenge: string }>,
>(
  deps: Deps,
  event: HttpApiEvent,
  schema: S,
): Promise<{ device: DeviceRecord; request: z.infer<S> }> {
  const headers = AssertionHeaders.safeParse({
    'x-tr-key-id': event.headers?.['x-tr-key-id'],
    'x-tr-assertion': event.headers?.['x-tr-assertion'],
  });
  if (!headers.success) {
    throw new ApiError('bad_request', 'Missing or malformed assertion headers');
  }
  const request = parseBody(event, schema);

  const device = await deps.store.getDevice(headers.data['x-tr-key-id']);
  if (!device) throw new ApiError('assertion_invalid', 'Unknown device');

  let counter: number;
  try {
    counter = verifyAssertion({
      assertion: Buffer.from(headers.data['x-tr-assertion'], 'base64'),
      body: rawBody(event),
      publicKeySpki: Buffer.from(device.publicKey, 'base64'),
      storedSignCount: device.signCount,
      appId: deps.appId,
    });
  } catch (err) {
    if (err instanceof AssertionError) {
      throw new ApiError('assertion_invalid', 'Assertion rejected');
    }
    throw err;
  }

  if (
    !(await deps.store.advanceSignCount(
      device.keyId,
      device.signCount,
      counter,
    ))
  ) {
    throw new ApiError('assertion_invalid', 'Assertion rejected');
  }
  const nowSeconds = Math.floor(deps.nowMs() / 1000);
  if (!(await deps.store.consumeChallenge(request.challenge, nowSeconds))) {
    throw new ApiError(
      'challenge_invalid',
      'Challenge expired or already used',
    );
  }
  return { device: { ...device, signCount: counter }, request };
}
