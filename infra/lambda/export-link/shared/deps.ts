import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { S3Client } from '@aws-sdk/client-s3';
import { SESv2Client } from '@aws-sdk/client-sesv2';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { randomBytes } from 'node:crypto';
import type { HttpApiEvent, HttpApiResult } from './http.js';
import { SesMailer, type Mailer } from './mailer.js';
import { S3ObjectStore, type ObjectStore } from './objects.js';
import { DynamoStore, type Store } from './store.js';
import { DynamoWaitlist, type Waitlist } from './waitlist.js';

export interface Deps {
  store: Store;
  waitlist: Waitlist;
  objects: ObjectStore;
  mailer: Mailer;
  feedbackFrom: string;
  feedbackTo: string;
  waitlistFrom: string;
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
    waitlist: new DynamoWaitlist(db, process.env.WAITLIST_TABLE_NAME ?? ''),
    objects: new S3ObjectStore(new S3Client({}), process.env.BUCKET_NAME ?? ''),
    mailer: new SesMailer(new SESv2Client({})),
    feedbackFrom: process.env.FEEDBACK_FROM_ADDRESS ?? '',
    feedbackTo: process.env.FEEDBACK_TO_ADDRESS ?? '',
    waitlistFrom: process.env.WAITLIST_FROM_ADDRESS ?? '',
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
