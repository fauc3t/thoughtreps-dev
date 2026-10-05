import {
  ChallengeResponse,
  RegisterDeviceResponse,
} from '../../../lib/export-link/schemas.js';
import {
  DEVELOPMENT_ATTESTATION,
  FIXTURE_APP_ID,
  FIXTURE_CHALLENGE,
  FIXTURE_ROOT_PEM,
  PRODUCTION_ATTESTATION,
} from '../shared/attestationFixture.js';
import { json, makeEnv } from '../shared/testSupport.js';
import { createHandler } from './index.js';

function setup() {
  const env = makeEnv();
  // The fixture certs are valid from the day they were generated.
  env.clock.ms = Date.now();
  env.appId = FIXTURE_APP_ID;
  env.attestationRootPem = FIXTURE_ROOT_PEM;
  env.store.challenges.set(
    FIXTURE_CHALLENGE,
    Math.floor(env.clock.ms / 1000) + 300,
  );
  return { env, handler: createHandler(env) };
}

const register = (body: unknown) => ({
  routeKey: 'POST /api/v1/devices',
  body: JSON.stringify(body),
});

describe('POST /api/v1/challenge', () => {
  it('issues a 32-byte base64url challenge that lives 5 minutes', async () => {
    const { env, handler } = setup();
    const res = await handler({ routeKey: 'POST /api/v1/challenge' });
    expect(res.statusCode).toBe(200);
    const body = ChallengeResponse.parse(json(res));
    expect(env.store.challenges.get(body.challenge)).toBe(
      Math.floor(env.clock.ms / 1000) + 300,
    );
    expect(Date.parse(body.expiresAt)).toBe(
      (Math.floor(env.clock.ms / 1000) + 300) * 1000,
    );
  });
});

describe('POST /api/v1/devices', () => {
  it('registers a valid production attestation and is retry-safe', async () => {
    const { env, handler } = setup();
    const body = {
      keyId: PRODUCTION_ATTESTATION.keyId,
      attestation: PRODUCTION_ATTESTATION.attestation,
      challenge: FIXTURE_CHALLENGE,
    };
    const res = await handler(register(body));
    expect(res.statusCode).toBe(200);
    RegisterDeviceResponse.parse(json(res));
    expect(env.store.devices.get(body.keyId)).toMatchObject({
      publicKey: PRODUCTION_ATTESTATION.publicKeySpki,
      signCount: 0,
      environment: 'production',
    });

    env.store.challenges.set(FIXTURE_CHALLENGE, env.clock.ms / 1000 + 300);
    expect((await handler(register(body))).statusCode).toBe(200);
  });

  it('consumes the challenge: replay is challenge_invalid', async () => {
    const { handler } = setup();
    const body = {
      keyId: PRODUCTION_ATTESTATION.keyId,
      attestation: PRODUCTION_ATTESTATION.attestation,
      challenge: FIXTURE_CHALLENGE,
    };
    await handler(register(body));
    const replay = await handler(register(body));
    expect(replay.statusCode).toBe(401);
    expect(json(replay).error).toBe('challenge_invalid');
  });

  it('rejects development attestations', async () => {
    const { env, handler } = setup();
    const res = await handler(
      register({
        keyId: DEVELOPMENT_ATTESTATION.keyId,
        attestation: DEVELOPMENT_ATTESTATION.attestation,
        challenge: FIXTURE_CHALLENGE,
      }),
    );
    expect(json(res).error).toBe('attestation_invalid');
    expect(env.store.devices.size).toBe(0);
  });

  it('rejects a chain that does not reach Apple root', async () => {
    const { env, handler } = setup();
    env.attestationRootPem = undefined;
    const res = await handler(
      register({
        keyId: PRODUCTION_ATTESTATION.keyId,
        attestation: PRODUCTION_ATTESTATION.attestation,
        challenge: FIXTURE_CHALLENGE,
      }),
    );
    expect(res.statusCode).toBe(401);
    expect(json(res).error).toBe('attestation_invalid');
    expect(env.store.devices.size).toBe(0);
  });

  it('rejects unknown challenges and malformed bodies', async () => {
    const { handler } = setup();
    const unknown = await handler(
      register({
        keyId: PRODUCTION_ATTESTATION.keyId,
        attestation: PRODUCTION_ATTESTATION.attestation,
        challenge: 'z'.repeat(43),
      }),
    );
    expect(json(unknown).error).toBe('challenge_invalid');

    for (const body of [
      {},
      { keyId: 'short', attestation: 'AAAA', challenge: FIXTURE_CHALLENGE },
      {
        keyId: PRODUCTION_ATTESTATION.keyId,
        attestation: 'AAAA',
        challenge: FIXTURE_CHALLENGE,
        extra: 1,
      },
    ]) {
      const res = await handler(register(body));
      expect(res.statusCode).toBe(400);
      expect(json(res).error).toBe('bad_request');
    }
    const notJson = await handler({
      routeKey: 'POST /api/v1/devices',
      body: 'nope',
    });
    expect(notJson.statusCode).toBe(400);
  });
});
