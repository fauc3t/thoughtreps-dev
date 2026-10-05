import {
  ClaimExportLinkResponse,
  ExportLinkStatusResponse,
  type ExportLinkRecord,
} from '../../../lib/export-link/schemas.js';
import { SHA, json, makeEnv } from '../shared/testSupport.js';
import { createHandler } from './index.js';

const ID = 'AAAAAAAAAAAAAAAAAAAAAA';
const KEY = `exports/${ID}`;

function setup(overrides: Partial<ExportLinkRecord> = {}) {
  const env = makeEnv();
  const now = Math.floor(env.clock.ms / 1000);
  const link: ExportLinkRecord = {
    pk: `EXPORT#${ID}`,
    exportLinkId: ID,
    keyId: Buffer.alloc(32, 3).toString('base64'),
    status: 'ready',
    sizeBytes: 4321,
    sha256: SHA,
    createdAt: now - 60,
    expiresAt: now + 3600,
    sweep: 'OPEN',
    sweepAt: now + 3600,
    ttl: now + 3600 + 7 * 86400,
    ...overrides,
  };
  env.store.links.set(ID, link);
  env.objects.stored.set(KEY, { sizeBytes: 4321, sha256: SHA });
  const handler = createHandler(env);
  const status = (id = ID) =>
    handler({
      routeKey: 'GET /api/v1/export-links/{id}',
      pathParameters: { id },
    });
  const claim = (id = ID) =>
    handler({
      routeKey: 'POST /api/v1/export-links/{id}/claim',
      pathParameters: { id },
    });
  const done = (id = ID) =>
    handler({
      routeKey: 'POST /api/v1/export-links/{id}/done',
      pathParameters: { id },
    });
  return { env, link, status, claim, done, now };
}

describe('GET status', () => {
  it('reports a ready link with size and expiry, and has no side effects', async () => {
    const { env, link, status } = setup();
    const before = structuredClone(link);
    for (let i = 0; i < 3; i++) {
      const res = await status();
      expect(res.statusCode).toBe(200);
      expect(ExportLinkStatusResponse.parse(json(res))).toEqual({
        status: 'ready',
        sizeBytes: 4321,
        expiresAt: new Date(link.expiresAt * 1000).toISOString(),
      });
    }
    expect(env.store.links.get(ID)).toEqual(before);
    expect(env.objects.deleted).toEqual([]);
  });

  it('404s for unknown and pending links', async () => {
    expect((await setup().status('B'.repeat(22))).statusCode).toBe(404);
    expect((await setup({ status: 'pending' }).status()).statusCode).toBe(404);
  });

  it('400s on a malformed id', async () => {
    const res = await setup().status('not-an-id');
    expect(res.statusCode).toBe(400);
    expect(json(res).error).toBe('bad_request');
  });

  it('reports used, revoked, expired and a past-expiry ready link as expired', async () => {
    for (const status of ['used', 'revoked', 'expired'] as const) {
      const res = await setup({ status }).status();
      expect(json(res)).toEqual({ status });
    }
    const { env, status } = setup();
    env.clock.ms += 3601_000;
    expect(json(await status())).toEqual({ status: 'expired' });
  });
});

describe('POST claim', () => {
  it('claims once: ready -> used, presigned GET for 5 minutes, sweep stays open', async () => {
    const { env, claim, now } = setup();
    const res = await claim();
    expect(res.statusCode).toBe(200);
    const body = ClaimExportLinkResponse.parse(json(res));
    expect(body.download.url).toBe(`https://s3.test/${KEY}?get&expires=300`);
    expect(Date.parse(body.download.expiresAt) / 1000).toBe(now + 300);
    expect(body.sizeBytes).toBe(4321);
    expect(body.sha256).toBe(SHA);
    expect(env.store.links.get(ID)).toMatchObject({
      status: 'used',
      claimedAt: now,
      sweep: 'OPEN',
      sweepAt: now + 600,
    });
  });

  it('answers 410 used to a second claim', async () => {
    const { claim } = setup();
    await claim();
    const second = await claim();
    expect(second.statusCode).toBe(410);
    expect(json(second).error).toBe('used');
  });

  it('only one of several concurrent claims wins', async () => {
    const { claim } = setup();
    const results = await Promise.all([claim(), claim(), claim()]);
    expect(results.filter((r) => r.statusCode === 200)).toHaveLength(1);
  });

  it('answers 410 expired past expiry, even before the sweeper ran', async () => {
    const { env, claim } = setup();
    env.clock.ms += 3601_000;
    const res = await claim();
    expect(res.statusCode).toBe(410);
    expect(json(res).error).toBe('expired');
    expect(env.store.links.get(ID)?.status).toBe('ready');
  });

  it('answers 410 revoked/expired and 404 unknown or pending', async () => {
    expect(json(await setup({ status: 'revoked' }).claim()).error).toBe(
      'revoked',
    );
    expect(json(await setup({ status: 'expired' }).claim()).error).toBe(
      'expired',
    );
    expect((await setup().claim('C'.repeat(22))).statusCode).toBe(404);
    expect((await setup({ status: 'pending' }).claim()).statusCode).toBe(404);
  });
});

describe('POST done', () => {
  it('deletes the object of a used link and closes the sweep', async () => {
    const { env, claim, done, now } = setup();
    await claim();
    const res = await done();
    expect(res.statusCode).toBe(204);
    expect(res.body).toBe('');
    expect(env.objects.stored.has(KEY)).toBe(false);
    const link = env.store.links.get(ID);
    expect(link).toMatchObject({ status: 'used', objectDeletedAt: now });
    expect(link?.sweep).toBeUndefined();
    expect(link?.sweepAt).toBeUndefined();
  });

  it('is idempotent', async () => {
    const { claim, done } = setup();
    await claim();
    expect((await done()).statusCode).toBe(204);
    expect((await done()).statusCode).toBe(204);
  });

  it('does nothing for a link that has not been claimed', async () => {
    const { env, done } = setup();
    expect((await done()).statusCode).toBe(204);
    expect(env.objects.deleted).toEqual([]);
    expect(env.store.links.get(ID)?.status).toBe('ready');
    expect((await done('D'.repeat(22))).statusCode).toBe(204);
  });
});

describe('routing', () => {
  it('404s unknown routes', async () => {
    const { env } = setup();
    const res = await createHandler(env)({ routeKey: 'GET /api/v1/other' });
    expect(res.statusCode).toBe(404);
  });
});
