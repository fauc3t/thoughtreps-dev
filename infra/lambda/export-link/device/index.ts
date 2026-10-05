import {
  ChallengeResponse,
  RegisterDeviceRequest,
  RegisterDeviceResponse,
} from '../../../lib/export-link/schemas.js';
import { verifyAttestation } from '../shared/appattest.js';
import { lazyHandler, type Deps, type Handler } from '../shared/deps.js';
import {
  ApiError,
  iso,
  jsonResponse,
  parseBody,
  type HttpApiEvent,
  toErrorResponse,
} from '../shared/http.js';

const CHALLENGE_TTL_SECONDS = 5 * 60;

export function createHandler(deps: Deps): Handler {
  const nowSeconds = () => Math.floor(deps.nowMs() / 1000);

  async function issueChallenge() {
    const challenge = deps.randomBytes(32).toString('base64url');
    const expiresAt = nowSeconds() + CHALLENGE_TTL_SECONDS;
    await deps.store.putChallenge(challenge, expiresAt);
    return jsonResponse(
      200,
      ChallengeResponse.parse({ challenge, expiresAt: iso(expiresAt) }),
    );
  }

  async function registerDevice(event: HttpApiEvent) {
    const request = parseBody(event, RegisterDeviceRequest);

    // Consumed before verifying so a failed attempt can't be retried with the
    // same challenge.
    if (!(await deps.store.consumeChallenge(request.challenge, nowSeconds()))) {
      throw new ApiError(
        'challenge_invalid',
        'Challenge expired or already used',
      );
    }

    let publicKeySpki: Buffer;
    try {
      ({ publicKeySpki } = verifyAttestation({
        attestation: Buffer.from(request.attestation, 'base64'),
        challenge: request.challenge,
        keyId: request.keyId,
        appId: deps.appId,
        now: new Date(deps.nowMs()),
        rootPem: deps.attestationRootPem,
      }));
    } catch {
      throw new ApiError('attestation_invalid', 'Attestation rejected');
    }

    // A false result means this key is already registered. The keyId is the
    // hash of the attested public key, so it is the same key and a client
    // retry after a lost response should succeed.
    await deps.store.putDevice({
      pk: `DEVICE#${request.keyId}`,
      keyId: request.keyId,
      publicKey: publicKeySpki.toString('base64'),
      signCount: 0,
      environment: 'production',
      createdAt: nowSeconds(),
    });
    return jsonResponse(
      200,
      RegisterDeviceResponse.parse({ registered: true }),
    );
  }

  return async (event) => {
    try {
      switch (event.routeKey) {
        case 'POST /api/v1/challenge':
          return await issueChallenge();
        case 'POST /api/v1/devices':
          return await registerDevice(event);
        default:
          throw new ApiError('not_found', 'Unknown route');
      }
    } catch (err) {
      return toErrorResponse(err);
    }
  };
}

export const handler = lazyHandler(createHandler);
