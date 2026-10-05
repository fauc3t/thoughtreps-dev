import { ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  QueryCommand,
  UpdateCommand,
  type DynamoDBDocumentClient,
} from '@aws-sdk/lib-dynamodb';
import {
  DeviceRecord,
  ExportLinkRecord,
  RateRecord,
} from '../../../lib/export-link/schemas.js';

export const OPEN_INDEX = 'openIndex';

// No key collision: keyIds are base64 (never contain '#'), so a scoped key
// always has one more segment than an unscoped one.
const rateKey = (keyId: string, day: string, scope?: string) =>
  `RATE#${scope ? `${scope}#` : ''}${keyId}#${day}`;
const SWEEP_PAGE_SIZE = 100;
const SWEEP_MAX_ITEMS = 500;

// Every method that can lose a race is a single conditional write that
// returns whether it won; nothing here read-modify-writes.
export interface Store {
  putChallenge(challenge: string, ttl: number): Promise<void>;
  // Single use: true only for the one caller that deletes an unexpired entry.
  // Expiry is checked here, not left to DynamoDB TTL, which lags by up to 48h.
  consumeChallenge(challenge: string, now: number): Promise<boolean>;

  getDevice(keyId: string): Promise<DeviceRecord | null>;
  putDevice(device: DeviceRecord): Promise<boolean>;
  advanceSignCount(keyId: string, from: number, to: number): Promise<boolean>;
  setCurrentLink(keyId: string, exportLinkId: string): Promise<void>;

  // Current count for that UTC day (0 if none), same `scope` as incrementRate.
  getRate(keyId: string, day: string, scope?: string): Promise<number>;

  // True while the device is under `limit` for that UTC day. `scope` gives a
  // separate budget; unscoped is the export-link create counter.
  incrementRate(
    keyId: string,
    day: string,
    limit: number,
    ttl: number,
    scope?: string,
  ): Promise<boolean>;

  getLink(exportLinkId: string): Promise<ExportLinkRecord | null>;
  putLink(link: ExportLinkRecord): Promise<void>;
  // pending/ready -> revoked, only for the owning device. Stays in the sweep
  // index (due now) until the caller has deleted the object and settled it.
  revokeLink(
    exportLinkId: string,
    keyId: string,
    now: number,
  ): Promise<boolean>;
  // pending (unexpired, owned) -> ready.
  markReady(
    exportLinkId: string,
    keyId: string,
    now: number,
    expiresAt: number,
    ttl: number,
  ): Promise<ExportLinkRecord | null>;
  // ready and unexpired -> used. Sweep stays open to delete a download that
  // never reported done.
  claimLink(
    exportLinkId: string,
    now: number,
    sweepAt: number,
  ): Promise<ExportLinkRecord | null>;
  // used -> object gone, sweep cleared.
  finishUsed(exportLinkId: string, now: number): Promise<boolean>;

  listDueForSweep(now: number): Promise<ExportLinkRecord[]>;
  // Records that the object is deleted. pending/ready become expired; any
  // other status is kept. Fails if the status moved since it was read.
  settleSwept(
    exportLinkId: string,
    seenStatus: ExportLinkRecord['status'],
    now: number,
  ): Promise<boolean>;
}

async function won(write: Promise<unknown>): Promise<boolean> {
  try {
    await write;
    return true;
  } catch (err) {
    if (err instanceof ConditionalCheckFailedException) return false;
    throw err;
  }
}

export class DynamoStore implements Store {
  constructor(
    private readonly db: DynamoDBDocumentClient,
    private readonly tableName: string,
  ) {}

  async putChallenge(challenge: string, ttl: number) {
    await this.db.send(
      new PutCommand({
        TableName: this.tableName,
        Item: { pk: `CHALLENGE#${challenge}`, ttl },
      }),
    );
  }

  consumeChallenge(challenge: string, now: number) {
    return won(
      this.db.send(
        new DeleteCommand({
          TableName: this.tableName,
          Key: { pk: `CHALLENGE#${challenge}` },
          ConditionExpression: 'attribute_exists(pk) AND #ttl > :now',
          ExpressionAttributeNames: { '#ttl': 'ttl' },
          ExpressionAttributeValues: { ':now': now },
        }),
      ),
    );
  }

  async getDevice(keyId: string) {
    const { Item } = await this.db.send(
      new GetCommand({
        TableName: this.tableName,
        Key: { pk: `DEVICE#${keyId}` },
        ConsistentRead: true,
      }),
    );
    return Item ? DeviceRecord.parse(Item) : null;
  }

  putDevice(device: DeviceRecord) {
    return won(
      this.db.send(
        new PutCommand({
          TableName: this.tableName,
          Item: device,
          ConditionExpression: 'attribute_not_exists(pk)',
        }),
      ),
    );
  }

  advanceSignCount(keyId: string, from: number, to: number) {
    return won(
      this.db.send(
        new UpdateCommand({
          TableName: this.tableName,
          Key: { pk: `DEVICE#${keyId}` },
          UpdateExpression: 'SET signCount = :to',
          ConditionExpression: 'signCount = :from',
          ExpressionAttributeValues: { ':from': from, ':to': to },
        }),
      ),
    );
  }

  async setCurrentLink(keyId: string, exportLinkId: string) {
    await this.db.send(
      new UpdateCommand({
        TableName: this.tableName,
        Key: { pk: `DEVICE#${keyId}` },
        UpdateExpression: 'SET currentExportLinkId = :id',
        ExpressionAttributeValues: { ':id': exportLinkId },
      }),
    );
  }

  async getRate(keyId: string, day: string, scope?: string) {
    const { Item } = await this.db.send(
      new GetCommand({
        TableName: this.tableName,
        Key: { pk: rateKey(keyId, day, scope) },
        ConsistentRead: true,
      }),
    );
    return Item ? RateRecord.parse(Item).count : 0;
  }

  incrementRate(
    keyId: string,
    day: string,
    limit: number,
    ttl: number,
    scope?: string,
  ) {
    return won(
      this.db.send(
        new UpdateCommand({
          TableName: this.tableName,
          Key: { pk: rateKey(keyId, day, scope) },
          UpdateExpression: 'ADD #count :one SET #ttl = :ttl',
          ConditionExpression:
            'attribute_not_exists(#count) OR #count < :limit',
          ExpressionAttributeNames: { '#count': 'count', '#ttl': 'ttl' },
          ExpressionAttributeValues: {
            ':one': 1,
            ':limit': limit,
            ':ttl': ttl,
          },
        }),
      ),
    );
  }

  async getLink(exportLinkId: string) {
    const { Item } = await this.db.send(
      new GetCommand({
        TableName: this.tableName,
        Key: { pk: `EXPORT#${exportLinkId}` },
        ConsistentRead: true,
      }),
    );
    return Item ? ExportLinkRecord.parse(Item) : null;
  }

  async putLink(link: ExportLinkRecord) {
    await this.db.send(
      new PutCommand({
        TableName: this.tableName,
        Item: link,
        ConditionExpression: 'attribute_not_exists(pk)',
      }),
    );
  }

  revokeLink(exportLinkId: string, keyId: string, now: number) {
    return won(
      this.db.send(
        new UpdateCommand({
          TableName: this.tableName,
          Key: { pk: `EXPORT#${exportLinkId}` },
          UpdateExpression: 'SET #status = :revoked, sweepAt = :now',
          ConditionExpression:
            'keyId = :keyId AND #status IN (:pending, :ready)',
          ExpressionAttributeNames: { '#status': 'status' },
          ExpressionAttributeValues: {
            ':revoked': 'revoked',
            ':now': now,
            ':keyId': keyId,
            ':pending': 'pending',
            ':ready': 'ready',
          },
        }),
      ),
    );
  }

  async markReady(
    exportLinkId: string,
    keyId: string,
    now: number,
    expiresAt: number,
    ttl: number,
  ) {
    return this.updateReturningNew(exportLinkId, {
      UpdateExpression:
        'SET #status = :ready, expiresAt = :expiresAt, sweepAt = :expiresAt, #ttl = :ttl',
      ConditionExpression:
        'keyId = :keyId AND #status = :pending AND expiresAt > :now',
      ExpressionAttributeNames: { '#status': 'status', '#ttl': 'ttl' },
      ExpressionAttributeValues: {
        ':ready': 'ready',
        ':pending': 'pending',
        ':keyId': keyId,
        ':now': now,
        ':expiresAt': expiresAt,
        ':ttl': ttl,
      },
    });
  }

  claimLink(exportLinkId: string, now: number, sweepAt: number) {
    return this.updateReturningNew(exportLinkId, {
      UpdateExpression:
        'SET #status = :used, claimedAt = :now, sweepAt = :sweepAt',
      ConditionExpression: '#status = :ready AND expiresAt > :now',
      ExpressionAttributeNames: { '#status': 'status' },
      ExpressionAttributeValues: {
        ':used': 'used',
        ':ready': 'ready',
        ':now': now,
        ':sweepAt': sweepAt,
      },
    });
  }

  finishUsed(exportLinkId: string, now: number) {
    return won(
      this.db.send(
        new UpdateCommand({
          TableName: this.tableName,
          Key: { pk: `EXPORT#${exportLinkId}` },
          UpdateExpression: 'SET objectDeletedAt = :now REMOVE sweep, sweepAt',
          ConditionExpression: '#status = :used',
          ExpressionAttributeNames: { '#status': 'status' },
          ExpressionAttributeValues: { ':used': 'used', ':now': now },
        }),
      ),
    );
  }

  async listDueForSweep(now: number) {
    const due: ExportLinkRecord[] = [];
    let startKey: Record<string, unknown> | undefined;
    do {
      const page = await this.db.send(
        new QueryCommand({
          TableName: this.tableName,
          IndexName: OPEN_INDEX,
          KeyConditionExpression: 'sweep = :open AND sweepAt <= :now',
          ExpressionAttributeValues: { ':open': 'OPEN', ':now': now },
          Limit: SWEEP_PAGE_SIZE,
          ExclusiveStartKey: startKey,
        }),
      );
      for (const item of page.Items ?? []) {
        due.push(ExportLinkRecord.parse(item));
      }
      startKey = page.LastEvaluatedKey;
    } while (startKey && due.length < SWEEP_MAX_ITEMS);
    return due;
  }

  settleSwept(
    exportLinkId: string,
    seenStatus: ExportLinkRecord['status'],
    now: number,
  ) {
    const becomesExpired = seenStatus === 'pending' || seenStatus === 'ready';
    return won(
      this.db.send(
        new UpdateCommand({
          TableName: this.tableName,
          Key: { pk: `EXPORT#${exportLinkId}` },
          UpdateExpression: becomesExpired
            ? 'SET objectDeletedAt = :now, #status = :expired REMOVE sweep, sweepAt'
            : 'SET objectDeletedAt = :now REMOVE sweep, sweepAt',
          ConditionExpression: '#status = :seen',
          ExpressionAttributeNames: { '#status': 'status' },
          ExpressionAttributeValues: {
            ':now': now,
            ':seen': seenStatus,
            ...(becomesExpired ? { ':expired': 'expired' } : {}),
          },
        }),
      ),
    );
  }

  private async updateReturningNew(
    exportLinkId: string,
    update: Pick<
      ConstructorParameters<typeof UpdateCommand>[0],
      | 'UpdateExpression'
      | 'ConditionExpression'
      | 'ExpressionAttributeNames'
      | 'ExpressionAttributeValues'
    >,
  ): Promise<ExportLinkRecord | null> {
    try {
      const { Attributes } = await this.db.send(
        new UpdateCommand({
          TableName: this.tableName,
          Key: { pk: `EXPORT#${exportLinkId}` },
          ReturnValues: 'ALL_NEW',
          ...update,
        }),
      );
      return ExportLinkRecord.parse(Attributes);
    } catch (err) {
      if (err instanceof ConditionalCheckFailedException) return null;
      throw err;
    }
  }
}
