import {
  CompleteExportLinkResponse,
  CreateExportLinkResponse,
  CurrentExportLinkResponse,
  MAX_UPLOAD_BYTES,
  RevokeExportLinkResponse,
} from '../../../lib/export-link/schemas.js';
import {
  SHA,
  json,
  makeEnv,
  registerTestDevice,
  signedEvent,
  type TestDevice,
  type TestEnv,
} from '../shared/testSupport.js';
import { createSweeper } from '../sweep/index.js';
import { CREATES_PER_DAY, createHandler } from './index.js';

const CREATE = 'POST /api/v1/export-links';
const COMPLETE = 'POST /api/v1/export-links/complete';
const CURRENT = 'POST /api/v1/export-links/current';
const REVOKE = 'POST /api/v1/export-links/revoke';

function setup() {
  const env = makeEnv();
  const device = registerTestDevice(env);
  const handler = createHandler(env);
  let counter = 0;
  const call = (
    routeKey: string,
    payload: Record<string, unknown> = {},
    options: { challenge?: string; signedBody?: string } = {},
  ) =>
    handler(
      signedEvent(env, device, routeKey, payload, {
        counter: ++counter,
        ...options,
      }),
    );
  const create = (sizeBytes = 1000) => call(CREATE, { sizeBytes, sha256: SHA });
  return { env, device, handler, call, create };
}

const nowSeconds = (env: TestEnv) => Math.floor(env.clock.ms / 1000);

function upload(env: TestEnv, exportLinkId: string, sizeBytes = 1000) {
  env.objects.stored.set(`exports/${exportLinkId}`, { sizeBytes, sha256: SHA });
}

async function createAndUpload(ctx: ReturnType<typeof setup>) {
  const res = await ctx.create();
  const { exportLinkId } = CreateExportLinkResponse.parse(json(res));
  upload(ctx.env, exportLinkId);
  return exportLinkId;
}

describe('authentication', () => {
  it('rejects missing headers as bad_request', async () => {
    const { handler } = setup();
    const res = await handler({ routeKey: CURRENT, body: '{}' });
    expect(res.statusCode).toBe(400);
  });

  it('rejects an unknown device', async () => {
    const env = makeEnv();
    const stranger = registerTestDevice(makeEnv());
    const res = await createHandler(env)(
      signedEvent(env, stranger, CURRENT, {}, { counter: 1 }),
    );
    expect(json(res).error).toBe('assertion_invalid');
  });

  it('rejects a body that differs from what was signed', async () => {
    const { call } = setup();
    const res = await call(
      CREATE,
      { sizeBytes: 1000, sha256: SHA },
      { signedBody: '{"something":"else"}' },
    );
    expect(res.statusCode).toBe(401);
    expect(json(res).error).toBe('assertion_invalid');
  });

  it('rejects a replayed assertion (counter must increase)', async () => {
    const { env, device, handler } = setup();
    const event = signedEvent(env, device, CURRENT, {}, { counter: 1 });
    expect((await handler(event)).statusCode).toBe(200);
    const replay = await handler(event);
    expect(replay.statusCode).toBe(401);
    expect(json(replay).error).toBe('assertion_invalid');
  });

  it('persists the new counter and rejects a lower one', async () => {
    const { env, device, handler } = setup();
    await handler(signedEvent(env, device, CURRENT, {}, { counter: 7 }));
    expect(env.store.devices.get(device.keyId)?.signCount).toBe(7);
    const lower = await handler(
      signedEvent(env, device, CURRENT, {}, { counter: 3 }),
    );
    expect(json(lower).error).toBe('assertion_invalid');
  });

  it('requires a fresh single-use challenge', async () => {
    const { env, call } = setup();
    const res = await call(CURRENT, {}, { challenge: 'q'.repeat(43) });
    expect(json(res).error).toBe('challenge_invalid');

    const challenge = 'r'.repeat(43);
    env.store.challenges.set(challenge, nowSeconds(env) + 300);
    expect((await call(CURRENT, {}, { challenge })).statusCode).toBe(200);
    expect(json(await call(CURRENT, {}, { challenge })).error).toBe(
      'challenge_invalid',
    );
  });

  it('rejects an expired challenge', async () => {
    const { env, call } = setup();
    const challenge = 's'.repeat(43);
    env.store.challenges.set(challenge, nowSeconds(env) - 1);
    expect(json(await call(CURRENT, {}, { challenge })).error).toBe(
      'challenge_invalid',
    );
  });
});

describe('create', () => {
  it('records a pending link and returns a presigned PUT with the signed headers', async () => {
    const { env, device, create } = setup();
    const res = await create(1234);
    expect(res.statusCode).toBe(200);
    const body = CreateExportLinkResponse.parse(json(res));
    expect(body.replacedExportLinkId).toBeNull();
    expect(body.exportLinkId).toHaveLength(22);
    expect(body.upload.method).toBe('PUT');
    expect(body.upload.url).toContain(`exports/${body.exportLinkId}`);
    expect(body.upload.headers).toEqual({
      'content-length': '1234',
      'x-amz-checksum-sha256': SHA,
    });

    const now = nowSeconds(env);
    expect(env.store.links.get(body.exportLinkId)).toEqual({
      pk: `EXPORT#${body.exportLinkId}`,
      exportLinkId: body.exportLinkId,
      keyId: device.keyId,
      status: 'pending',
      sizeBytes: 1234,
      sha256: SHA,
      createdAt: now,
      expiresAt: now + 600,
      sweep: 'OPEN',
      sweepAt: now + 600,
      ttl: now + 600 + 7 * 86400,
    });
    expect(env.store.devices.get(device.keyId)?.currentExportLinkId).toBe(
      body.exportLinkId,
    );
  });

  it('replaces (revokes and deletes) the device current open link', async () => {
    const ctx = setup();
    const first = await createAndUpload(ctx);
    const res = await ctx.create();
    const body = CreateExportLinkResponse.parse(json(res));
    expect(body.replacedExportLinkId).toBe(first);
    const old = ctx.env.store.links.get(first);
    expect(old?.status).toBe('revoked');
    expect(old?.sweep).toBeUndefined();
    expect(old?.objectDeletedAt).toBeDefined();
    expect(ctx.env.objects.deleted).toContain(`exports/${first}`);
    expect(ctx.env.objects.stored.has(`exports/${first}`)).toBe(false);
  });

  it('does not report a replacement when the previous link is already used', async () => {
    const ctx = setup();
    const first = await createAndUpload(ctx);
    const link = ctx.env.store.links.get(first);
    if (link) link.status = 'used';
    const body = CreateExportLinkResponse.parse(json(await ctx.create()));
    expect(body.replacedExportLinkId).toBeNull();
    expect(ctx.env.store.links.get(first)?.status).toBe('used');
  });

  it(`limits ${CREATES_PER_DAY} creates per device per UTC day`, async () => {
    const { env, create } = setup();
    for (let i = 0; i < CREATES_PER_DAY; i++) {
      expect((await create()).statusCode).toBe(200);
    }
    const limited = await create();
    expect(limited.statusCode).toBe(429);
    expect(json(limited).error).toBe('rate_limited');

    env.clock.ms += 24 * 60 * 60 * 1000;
    expect((await create()).statusCode).toBe(200);
  });

  it('answers too_large above the size cap and bad_request for other invalid bodies', async () => {
    const { env, call } = setup();
    const tooLarge = await call(CREATE, {
      sizeBytes: MAX_UPLOAD_BYTES + 1,
      sha256: SHA,
    });
    expect(tooLarge.statusCode).toBe(413);
    expect(json(tooLarge).error).toBe('too_large');

    for (const payload of [
      { sizeBytes: 0, sha256: SHA },
      { sizeBytes: 10, sha256: 'nope' },
      { sizeBytes: 10, sha256: SHA, extra: true },
      { sha256: SHA },
    ]) {
      const res = await call(CREATE, payload);
      expect(res.statusCode).toBe(400);
      expect(json(res).error).toBe('bad_request');
    }
    expect(env.store.links.size).toBe(0);
  });
});

describe('complete', () => {
  it('marks a verified upload ready for 24 hours', async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    ctx.env.clock.ms += 60_000;
    const res = await ctx.call(COMPLETE, { exportLinkId: id });
    expect(res.statusCode).toBe(200);
    const body = CompleteExportLinkResponse.parse(json(res));
    const now = nowSeconds(ctx.env);
    expect(body.status).toBe('ready');
    expect(Date.parse(body.expiresAt) / 1000).toBe(now + 86400);
    expect(ctx.env.store.links.get(id)).toMatchObject({
      status: 'ready',
      expiresAt: now + 86400,
      sweepAt: now + 86400,
      sweep: 'OPEN',
      ttl: now + 86400 + 7 * 86400,
    });
  });

  it('fails with upload_mismatch and deletes the object when the size differs', async () => {
    const ctx = setup();
    const res = await ctx.create(1000);
    const { exportLinkId } = CreateExportLinkResponse.parse(json(res));
    upload(ctx.env, exportLinkId, 999);

    const done = await ctx.call(COMPLETE, { exportLinkId });
    expect(done.statusCode).toBe(409);
    expect(json(done).error).toBe('upload_mismatch');
    expect(ctx.env.objects.deleted).toContain(`exports/${exportLinkId}`);
    expect(ctx.env.store.links.get(exportLinkId)?.status).toBe('pending');
  });

  it('fails with upload_mismatch when the checksum differs or nothing was uploaded', async () => {
    const ctx = setup();
    const { exportLinkId } = CreateExportLinkResponse.parse(
      json(await ctx.create(1000)),
    );
    const missing = await ctx.call(COMPLETE, { exportLinkId });
    expect(json(missing).error).toBe('upload_mismatch');

    ctx.env.objects.stored.set(`exports/${exportLinkId}`, {
      sizeBytes: 1000,
      sha256: Buffer.alloc(32, 1).toString('base64'),
    });
    const wrongSum = await ctx.call(COMPLETE, { exportLinkId });
    expect(json(wrongSum).error).toBe('upload_mismatch');
  });

  it("answers not_found for another device's link or an unknown id", async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    const other = registerTestDevice(ctx.env);
    const stolen = await ctx.handler(
      signedEvent(
        ctx.env,
        other,
        COMPLETE,
        { exportLinkId: id },
        { counter: 1 },
      ),
    );
    expect(stolen.statusCode).toBe(404);

    const unknown = await ctx.call(COMPLETE, { exportLinkId: 'a'.repeat(22) });
    expect(unknown.statusCode).toBe(404);
  });

  it('is idempotent once ready: same summary, no writes, no S3 calls, expiry unchanged', async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    const first = await ctx.call(COMPLETE, { exportLinkId: id });
    const snapshot = structuredClone(ctx.env.store.links.get(id));
    const deletedBefore = [...ctx.env.objects.deleted];
    const head = jest.spyOn(ctx.env.objects, 'head');
    ctx.env.clock.ms += 3600_000;

    const second = await ctx.call(COMPLETE, { exportLinkId: id });
    expect(second.statusCode).toBe(200);
    expect(second.body).toBe(first.body);
    expect(ctx.env.store.links.get(id)).toEqual(snapshot);
    expect(head).not.toHaveBeenCalled();
    expect(ctx.env.objects.deleted).toEqual(deletedBefore);
  });

  it("answers not_found for another device's ready link", async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    await ctx.call(COMPLETE, { exportLinkId: id });
    const other = registerTestDevice(ctx.env);
    const res = await ctx.handler(
      signedEvent(
        ctx.env,
        other,
        COMPLETE,
        { exportLinkId: id },
        { counter: 1 },
      ),
    );
    expect(res.statusCode).toBe(404);
  });

  it('answers expired for a ready link past its expiry', async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    await ctx.call(COMPLETE, { exportLinkId: id });
    ctx.env.clock.ms += 25 * 3600_000;
    const res = await ctx.call(COMPLETE, { exportLinkId: id });
    expect(res.statusCode).toBe(410);
    expect(json(res).error).toBe('expired');
  });

  it('refuses once the upload window has passed or the link is not pending', async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    ctx.env.clock.ms += 601_000;
    const late = await ctx.call(COMPLETE, { exportLinkId: id });
    expect(json(late).error).toBe('expired');

    const ctx2 = setup();
    const id2 = await createAndUpload(ctx2);
    await ctx2.call(REVOKE, { exportLinkId: id2 });
    const revoked = await ctx2.call(COMPLETE, { exportLinkId: id2 });
    expect(json(revoked).error).toBe('revoked');
  });
});

describe('current', () => {
  it('returns the pending or ready link, else null', async () => {
    const ctx = setup();
    expect(
      CurrentExportLinkResponse.parse(json(await ctx.call(CURRENT))),
    ).toEqual({ exportLink: null });

    const id = await createAndUpload(ctx);
    const pending = CurrentExportLinkResponse.parse(
      json(await ctx.call(CURRENT)),
    );
    expect(pending.exportLink).toMatchObject({
      exportLinkId: id,
      status: 'pending',
      sizeBytes: 1000,
    });

    await ctx.call(COMPLETE, { exportLinkId: id });
    const ready = CurrentExportLinkResponse.parse(
      json(await ctx.call(CURRENT)),
    );
    expect(ready.exportLink?.status).toBe('ready');
  });

  it('returns null once the link is revoked, used or expired', async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    await ctx.call(COMPLETE, { exportLinkId: id });

    ctx.env.clock.ms += 25 * 60 * 60 * 1000;
    expect(json(await ctx.call(CURRENT)).exportLink).toBeNull();

    const link = ctx.env.store.links.get(id);
    if (link)
      Object.assign(link, {
        status: 'used',
        expiresAt: nowSeconds(ctx.env) + 100,
      });
    expect(json(await ctx.call(CURRENT)).exportLink).toBeNull();
  });
});

describe('revoke', () => {
  it('revokes the own link, deletes the object and clears the sweep', async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    const res = await ctx.call(REVOKE, { exportLinkId: id });
    expect(res.statusCode).toBe(200);
    RevokeExportLinkResponse.parse(json(res));
    expect(ctx.env.store.links.get(id)).toMatchObject({ status: 'revoked' });
    expect(ctx.env.store.links.get(id)?.sweep).toBeUndefined();
    expect(ctx.env.objects.stored.has(`exports/${id}`)).toBe(false);
  });

  it('keeps the link in the sweep index when the S3 delete fails, and the sweeper finishes the job', async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    const realDelete = ctx.env.objects.delete.bind(ctx.env.objects);
    ctx.env.objects.delete = async () => {
      throw new Error('s3 down');
    };
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const failed = await ctx.call(REVOKE, { exportLinkId: id });
    expect(failed.statusCode).toBe(500);

    const link = ctx.env.store.links.get(id);
    expect(link?.status).toBe('revoked');
    expect(link?.sweep).toBe('OPEN');
    expect(link?.sweepAt).toBeLessThanOrEqual(nowSeconds(ctx.env));
    expect(ctx.env.objects.stored.has(`exports/${id}`)).toBe(true);

    ctx.env.objects.delete = realDelete;
    jest.spyOn(console, 'log').mockImplementation(() => undefined);
    await createSweeper(ctx.env)();
    expect(ctx.env.objects.stored.has(`exports/${id}`)).toBe(false);
    expect(ctx.env.store.links.get(id)).toMatchObject({ status: 'revoked' });
    expect(ctx.env.store.links.get(id)?.sweep).toBeUndefined();
  });

  it('is idempotent for an already revoked link and 404s for strangers', async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    await ctx.call(REVOKE, { exportLinkId: id });
    expect((await ctx.call(REVOKE, { exportLinkId: id })).statusCode).toBe(200);

    const other: TestDevice = registerTestDevice(ctx.env);
    const stolen = await ctx.handler(
      signedEvent(ctx.env, other, REVOKE, { exportLinkId: id }, { counter: 1 }),
    );
    expect(stolen.statusCode).toBe(404);
  });

  it('refuses to revoke a link that was already used', async () => {
    const ctx = setup();
    const id = await createAndUpload(ctx);
    const link = ctx.env.store.links.get(id);
    if (link) link.status = 'used';
    const res = await ctx.call(REVOKE, { exportLinkId: id });
    expect(json(res).error).toBe('used');
  });
});

describe('routing', () => {
  it('404s unknown routes', async () => {
    const { handler } = setup();
    expect((await handler({ routeKey: 'POST /api/v1/nope' })).statusCode).toBe(
      404,
    );
  });
});
