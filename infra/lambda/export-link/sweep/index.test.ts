import type { ExportLinkRecord } from '../../../lib/export-link/schemas.js';
import { SHA, makeEnv, type TestEnv } from '../shared/testSupport.js';
import { createSweeper } from './index.js';

function addLink(
  env: TestEnv,
  id: string,
  overrides: Partial<ExportLinkRecord>,
) {
  const now = Math.floor(env.clock.ms / 1000);
  env.store.links.set(id, {
    pk: `EXPORT#${id}`,
    exportLinkId: id,
    keyId: Buffer.alloc(32, 3).toString('base64'),
    status: 'ready',
    sizeBytes: 10,
    sha256: SHA,
    createdAt: now - 1000,
    expiresAt: now - 10,
    sweep: 'OPEN',
    sweepAt: now - 10,
    ttl: now + 86400,
    ...overrides,
  });
  env.objects.stored.set(`exports/${id}`, { sizeBytes: 10, sha256: SHA });
}

describe('sweeper', () => {
  it('expires pending and ready links past their sweepAt and deletes their objects', async () => {
    const env = makeEnv();
    addLink(env, 'P'.repeat(22), { status: 'pending' });
    addLink(env, 'R'.repeat(22), { status: 'ready' });
    const result = await createSweeper(env)();
    expect(result).toEqual({ swept: 2, failed: 0 });

    const now = Math.floor(env.clock.ms / 1000);
    for (const id of ['P'.repeat(22), 'R'.repeat(22)]) {
      const link = env.store.links.get(id);
      expect(link).toMatchObject({ status: 'expired', objectDeletedAt: now });
      expect(link?.sweep).toBeUndefined();
      expect(link?.sweepAt).toBeUndefined();
      expect(env.objects.stored.has(`exports/${id}`)).toBe(false);
    }
  });

  it('keeps status used for a claimed download nobody reported done', async () => {
    const env = makeEnv();
    addLink(env, 'U'.repeat(22), { status: 'used' });
    await createSweeper(env)();
    const link = env.store.links.get('U'.repeat(22));
    expect(link?.status).toBe('used');
    expect(link?.objectDeletedAt).toBeDefined();
    expect(link?.sweep).toBeUndefined();
    expect(env.objects.deleted).toContain(`exports/${'U'.repeat(22)}`);
  });

  it('leaves links that are not yet due and links with no open sweep alone', async () => {
    const env = makeEnv();
    const now = Math.floor(env.clock.ms / 1000);
    addLink(env, 'F'.repeat(22), { status: 'ready', sweepAt: now + 100 });
    addLink(env, 'D'.repeat(22), {
      status: 'used',
      sweep: undefined,
      sweepAt: undefined,
      objectDeletedAt: now - 5,
    });
    expect(await createSweeper(env)()).toEqual({ swept: 0, failed: 0 });
    expect(env.objects.deleted).toEqual([]);
    expect(env.store.links.get('F'.repeat(22))?.status).toBe('ready');
  });

  it('keeps going past a failure and then reports it', async () => {
    const env = makeEnv();
    addLink(env, 'A'.repeat(22), { status: 'ready' });
    addLink(env, 'B'.repeat(22), { status: 'ready' });
    const realDelete = env.objects.delete.bind(env.objects);
    env.objects.delete = async (key: string) => {
      if (key.endsWith('A'.repeat(22))) throw new Error('boom');
      await realDelete(key);
    };
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
    jest.spyOn(console, 'log').mockImplementation(() => undefined);

    await expect(createSweeper(env)()).rejects.toThrow('1 export links failed');
    expect(env.store.links.get('B'.repeat(22))?.status).toBe('expired');
    expect(env.store.links.get('A'.repeat(22))?.status).toBe('ready');
    expect(env.store.links.get('A'.repeat(22))?.sweep).toBe('OPEN');
  });
});
