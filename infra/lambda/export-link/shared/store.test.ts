import {
  ConditionalCheckFailedException,
  DynamoDBClient,
} from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { SHA } from './testSupport.js';
import { DynamoStore } from './store.js';

const ID = 'AAAAAAAAAAAAAAAAAAAAAA';
const KEY_ID = Buffer.alloc(32, 3).toString('base64');

const conditionalFailure = () =>
  new ConditionalCheckFailedException({ message: 'no', $metadata: {} });

function setup(respond: (input: Record<string, unknown>) => unknown) {
  const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
  const calls: Array<{ name: string; input: Record<string, unknown> }> = [];
  jest.spyOn(db, 'send').mockImplementation(async (command: unknown) => {
    const { input, constructor } = command as {
      input: Record<string, unknown>;
      constructor: { name: string };
    };
    calls.push({ name: constructor.name, input });
    const out = respond(input);
    if (out instanceof Error) throw out;
    return out as never;
  });
  return { store: new DynamoStore(db, 'Table'), calls };
}

const record = (status: string) => ({
  pk: `EXPORT#${ID}`,
  exportLinkId: ID,
  keyId: KEY_ID,
  status,
  sizeBytes: 5,
  sha256: SHA,
  createdAt: 1,
  expiresAt: 2,
  ttl: 3,
});

describe('DynamoStore', () => {
  it('consumes a challenge only if it exists and has not expired', async () => {
    const { store, calls } = setup(() => ({}));
    await expect(store.consumeChallenge('c', 100)).resolves.toBe(true);
    expect(calls[0]).toMatchObject({
      name: 'DeleteCommand',
      input: {
        Key: { pk: 'CHALLENGE#c' },
        ConditionExpression: 'attribute_exists(pk) AND #ttl > :now',
        ExpressionAttributeValues: { ':now': 100 },
      },
    });

    const lost = setup(() => conditionalFailure());
    await expect(lost.store.consumeChallenge('c', 100)).resolves.toBe(false);
  });

  it('rethrows non-conditional errors', async () => {
    const { store } = setup(() => new Error('throttled'));
    await expect(store.consumeChallenge('c', 1)).rejects.toThrow('throttled');
  });

  it('advances the counter only from the value that was read', async () => {
    const { store, calls } = setup(() => ({}));
    await store.advanceSignCount(KEY_ID, 4, 5);
    expect(calls[0].input).toMatchObject({
      ConditionExpression: 'signCount = :from',
      ExpressionAttributeValues: { ':from': 4, ':to': 5 },
    });
  });

  it('rate limits with an atomic conditional ADD', async () => {
    const { store, calls } = setup(() => ({}));
    await store.incrementRate(KEY_ID, '2026-01-15', 10, 99);
    expect(calls[0].input).toMatchObject({
      Key: { pk: `RATE#${KEY_ID}#2026-01-15` },
      UpdateExpression: 'ADD #count :one SET #ttl = :ttl',
      ConditionExpression: 'attribute_not_exists(#count) OR #count < :limit',
      ExpressionAttributeValues: { ':limit': 10, ':ttl': 99 },
    });
    const full = setup(() => conditionalFailure());
    await expect(full.store.incrementRate(KEY_ID, 'd', 10, 1)).resolves.toBe(
      false,
    );
  });

  it('claims only a ready, unexpired link', async () => {
    const { store, calls } = setup(() => ({ Attributes: record('used') }));
    await expect(store.claimLink(ID, 50, 650)).resolves.toMatchObject({
      status: 'used',
    });
    expect(calls[0].input).toMatchObject({
      ConditionExpression: '#status = :ready AND expiresAt > :now',
      ReturnValues: 'ALL_NEW',
    });
    expect(calls[0].input.UpdateExpression).not.toContain('REMOVE');

    const lost = setup(() => conditionalFailure());
    await expect(lost.store.claimLink(ID, 50, 650)).resolves.toBeNull();
  });

  it('completes only the owner own pending, unexpired link', async () => {
    const { store, calls } = setup(() => ({ Attributes: record('ready') }));
    await store.markReady(ID, KEY_ID, 10, 20, 30);
    expect(calls[0].input.ConditionExpression).toBe(
      'keyId = :keyId AND #status = :pending AND expiresAt > :now',
    );
  });

  it('revokes only the owner own pending/ready link and keeps it in the sweep index, due now', async () => {
    const { store, calls } = setup(() => ({}));
    await store.revokeLink(ID, KEY_ID, 77);
    expect(calls[0].input).toMatchObject({
      UpdateExpression: 'SET #status = :revoked, sweepAt = :now',
      ConditionExpression: 'keyId = :keyId AND #status IN (:pending, :ready)',
    });
  });

  it('queries the sparse index for due records and follows pagination', async () => {
    let page = 0;
    const { store, calls } = setup(() =>
      page++ === 0
        ? {
            Items: [{ ...record('ready'), sweep: 'OPEN', sweepAt: 1 }],
            LastEvaluatedKey: { pk: 'x' },
          }
        : { Items: [{ ...record('used'), sweep: 'OPEN', sweepAt: 1 }] },
    );
    const due = await store.listDueForSweep(1000);
    expect(due.map((link) => link.status)).toEqual(['ready', 'used']);
    expect(calls[0].input).toMatchObject({
      IndexName: 'openIndex',
      KeyConditionExpression: 'sweep = :open AND sweepAt <= :now',
      ExpressionAttributeValues: { ':open': 'OPEN', ':now': 1000 },
    });
    expect(calls[1].input.ExclusiveStartKey).toEqual({ pk: 'x' });
  });

  it('settles a swept pending/ready record as expired and keeps other statuses', async () => {
    const { store, calls } = setup(() => ({}));
    await store.settleSwept(ID, 'ready', 5);
    await store.settleSwept(ID, 'used', 5);
    expect(calls[0].input.UpdateExpression).toContain('#status = :expired');
    expect(calls[1].input.UpdateExpression).not.toContain(':expired');
    for (const call of calls) {
      expect(call.input.ConditionExpression).toBe('#status = :seen');
      expect(call.input.UpdateExpression).toContain('REMOVE sweep, sweepAt');
    }
  });

  it('finishes only used links', async () => {
    const { store, calls } = setup(() => ({}));
    await store.finishUsed(ID, 5);
    expect(calls[0].input.ConditionExpression).toBe('#status = :used');
  });

  it('creates links and devices only if absent', async () => {
    const { store, calls } = setup(() => ({}));
    await store.putLink({
      ...record('pending'),
      pk: `EXPORT#${ID}`,
      status: 'pending',
    });
    expect(calls[0].input.ConditionExpression).toBe('attribute_not_exists(pk)');
  });
});
