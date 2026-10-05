import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { S3Client } from '@aws-sdk/client-s3';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { randomBytes } from 'node:crypto';
import type { HttpApiEvent, HttpApiResult } from './http.js';
import { S3ObjectStore, type ObjectStore } from './objects.js';
import { DynamoStore, type Store } from './store.js';

export interface Deps {
  store: Store;
  objects: ObjectStore;
  appId: string;
  // Tests only: production never sets it, so attestations are always
  // validated against Apple's root.
  attestationRootPem?: string;
  nowMs: () => number;
  randomBytes: (size: number) => Buffer;
}

export function defaultDeps(): Deps {
  const db = DynamoDBDocumentClient.from(new DynamoDBClient({}), {
    marshallOptions: { removeUndefinedValues: true },
  });
  return {
    store: new DynamoStore(db, process.env.TABLE_NAME ?? ''),
    objects: new S3ObjectStore(new S3Client({}), process.env.BUCKET_NAME ?? ''),
    appId: process.env.APP_ATTEST_APP_ID ?? '',
    nowMs: () => Date.now(),
    randomBytes,
  };
}

export type Handler = (event: HttpApiEvent) => Promise<HttpApiResult>;

// Builds the real clients on first invocation rather than at import time.
export function lazyHandler(create: (deps: Deps) => Handler): Handler {
  let handler: Handler | undefined;
  return (event) => (handler ??= create(defaultDeps()))(event);
}
