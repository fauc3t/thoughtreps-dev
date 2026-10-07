import {
  createHash,
  generateKeyPairSync,
  randomBytes,
  sign,
  type KeyObject,
} from 'node:crypto';
import type {
  DeviceRecord,
  ExportLinkRecord,
} from '../../../lib/export-link/schemas.js';
import type { Deps } from './deps.js';
import type { HttpApiEvent } from './http.js';
import type { Mailer, OutgoingMail } from './mailer.js';
import type { ObjectStore } from './objects.js';
import type { Store } from './store.js';
import type { Waitlist } from './waitlist.js';

export const APP_ID = 'TEAMID1234.com.example.app';
export const FEEDBACK_FROM = 'feedback@example.test';
export const FEEDBACK_TO = 'hello@example.test';
export const WAITLIST_FROM = 'waitlist@example.test';
export const T0_MS = Date.UTC(2026, 0, 15, 12, 0, 0);

const sha256 = (...parts: Uint8Array[]) =>
  createHash('sha256').update(Buffer.concat(parts)).digest();

export class FakeStore implements Store {
  challenges = new Map<string, number>();
  devices = new Map<string, DeviceRecord>();
  links = new Map<string, ExportLinkRecord>();
  rates = new Map<string, number>();

  async putChallenge(challenge: string, ttl: number) {
    this.challenges.set(challenge, ttl);
  }

  async consumeChallenge(challenge: string, now: number) {
    const ttl = this.challenges.get(challenge);
    if (ttl === undefined || ttl <= now) return false;
    this.challenges.delete(challenge);
    return true;
  }

  async getDevice(keyId: string) {
    return this.devices.get(keyId) ?? null;
  }

  async putDevice(device: DeviceRecord) {
    if (this.devices.has(device.keyId)) return false;
    this.devices.set(device.keyId, device);
    return true;
  }

  async advanceSignCount(keyId: string, from: number, to: number) {
    const device = this.devices.get(keyId);
    if (!device || device.signCount !== from) return false;
    device.signCount = to;
    return true;
  }

  async setCurrentLink(keyId: string, exportLinkId: string) {
    const device = this.devices.get(keyId);
    if (device) device.currentExportLinkId = exportLinkId;
  }

  async getRate(keyId: string, day: string, scope?: string) {
    return this.rates.get(`${scope ? `${scope}#` : ''}${keyId}#${day}`) ?? 0;
  }

  async incrementRate(
    keyId: string,
    day: string,
    limit: number,
    _ttl?: number,
    scope?: string,
  ) {
    const key = `${scope ? `${scope}#` : ''}${keyId}#${day}`;
    const count = this.rates.get(key) ?? 0;
    if (count >= limit) return false;
    this.rates.set(key, count + 1);
    return true;
  }

  async getLink(exportLinkId: string) {
    return this.links.get(exportLinkId) ?? null;
  }

  async putLink(link: ExportLinkRecord) {
    this.links.set(link.exportLinkId, link);
  }

  async revokeLink(exportLinkId: string, keyId: string, now: number) {
    const link = this.links.get(exportLinkId);
    if (
      !link ||
      link.keyId !== keyId ||
      (link.status !== 'pending' && link.status !== 'ready')
    ) {
      return false;
    }
    link.status = 'revoked';
    link.sweepAt = now;
    return true;
  }

  async markReady(
    exportLinkId: string,
    keyId: string,
    now: number,
    expiresAt: number,
    ttl: number,
  ) {
    const link = this.links.get(exportLinkId);
    if (
      !link ||
      link.keyId !== keyId ||
      link.status !== 'pending' ||
      link.expiresAt <= now
    ) {
      return null;
    }
    Object.assign(link, {
      status: 'ready',
      expiresAt,
      sweepAt: expiresAt,
      ttl,
    });
    return { ...link };
  }

  async claimLink(exportLinkId: string, now: number, sweepAt: number) {
    const link = this.links.get(exportLinkId);
    if (!link || link.status !== 'ready' || link.expiresAt <= now) return null;
    Object.assign(link, { status: 'used', claimedAt: now, sweepAt });
    return { ...link };
  }

  async finishUsed(exportLinkId: string, now: number) {
    const link = this.links.get(exportLinkId);
    if (!link || link.status !== 'used') return false;
    link.objectDeletedAt = now;
    delete link.sweep;
    delete link.sweepAt;
    return true;
  }

  async listDueForSweep(now: number) {
    return [...this.links.values()]
      .filter(
        (link) =>
          link.sweep === 'OPEN' &&
          link.sweepAt !== undefined &&
          link.sweepAt <= now,
      )
      .map((link) => ({ ...link }));
  }

  async settleSwept(
    exportLinkId: string,
    seenStatus: ExportLinkRecord['status'],
    now: number,
  ) {
    const link = this.links.get(exportLinkId);
    if (!link || link.status !== seenStatus) return false;
    if (seenStatus === 'pending' || seenStatus === 'ready') {
      link.status = 'expired';
    }
    link.objectDeletedAt = now;
    delete link.sweep;
    delete link.sweepAt;
    return true;
  }
}

export class FakeWaitlist implements Waitlist {
  rows = new Map<string, { beta: boolean; createdAt: string }>();

  async signUp(email: string, beta: boolean, createdAt: string) {
    const row = this.rows.get(email);
    if (!row) {
      this.rows.set(email, { beta, createdAt });
      return true;
    }
    if (beta) row.beta = true;
    return false;
  }
}

export class FakeObjects implements ObjectStore {
  stored = new Map<string, { sizeBytes: number; sha256: string }>();
  deleted: string[] = [];

  async presignPut(
    key: string,
    upload: { sizeBytes: number; sha256: string; expiresInSeconds: number },
  ) {
    return {
      url: `https://s3.test/${key}?put&expires=${upload.expiresInSeconds}`,
      headers: {
        'content-length': String(upload.sizeBytes),
        'x-amz-checksum-sha256': upload.sha256,
      },
    };
  }

  async presignGet(key: string, expiresInSeconds: number) {
    return `https://s3.test/${key}?get&expires=${expiresInSeconds}`;
  }

  async head(key: string) {
    return this.stored.get(key) ?? null;
  }

  async delete(key: string) {
    this.stored.delete(key);
    this.deleted.push(key);
  }
}

export class FakeMailer implements Mailer {
  sent: OutgoingMail[] = [];
  failWith: Error | null = null;

  async send(mail: OutgoingMail) {
    if (this.failWith) throw this.failWith;
    this.sent.push(mail);
  }
}

export interface TestEnv extends Deps {
  store: FakeStore;
  waitlist: FakeWaitlist;
  objects: FakeObjects;
  mailer: FakeMailer;
  clock: { ms: number };
}

export function makeEnv(): TestEnv {
  const clock = { ms: T0_MS };
  return {
    store: new FakeStore(),
    waitlist: new FakeWaitlist(),
    objects: new FakeObjects(),
    mailer: new FakeMailer(),
    feedbackFrom: FEEDBACK_FROM,
    feedbackTo: FEEDBACK_TO,
    waitlistFrom: WAITLIST_FROM,
    appId: APP_ID,
    nowMs: () => clock.ms,
    randomBytes,
    clock,
  };
}

const textHead = (major: number, length: number) =>
  length < 24 ? [(major << 5) | length] : [(major << 5) | 24, length];

function cborText(text: string) {
  const bytes = Buffer.from(text, 'utf8');
  return Buffer.concat([Buffer.from(textHead(3, bytes.length)), bytes]);
}

function cborBytes(bytes: Uint8Array) {
  const head =
    bytes.length < 24
      ? [(2 << 5) | bytes.length]
      : bytes.length < 256
        ? [(2 << 5) | 24, bytes.length]
        : [(2 << 5) | 25, bytes.length >> 8, bytes.length & 0xff];
  return Buffer.concat([Buffer.from(head), bytes]);
}

export function cborMap(entries: [string, Uint8Array][]) {
  return Buffer.concat([
    Buffer.from([(5 << 5) | entries.length]),
    ...entries.flatMap(([key, value]) => [cborText(key), cborBytes(value)]),
  ]);
}

export function authData(options: { appId?: string; counter: number }) {
  const out = Buffer.alloc(37);
  sha256(Buffer.from(options.appId ?? APP_ID)).copy(out, 0);
  out[32] = 0x40;
  out.writeUInt32BE(options.counter, 33);
  return out;
}

export interface TestDevice {
  keyId: string;
  privateKey: KeyObject;
  record: DeviceRecord;
}

export function registerTestDevice(env: TestEnv): TestDevice {
  const { publicKey, privateKey } = generateKeyPairSync('ec', {
    namedCurve: 'P-256',
  });
  const keyId = randomBytes(32).toString('base64');
  const record: DeviceRecord = {
    pk: `DEVICE#${keyId}`,
    keyId,
    publicKey: publicKey
      .export({ format: 'der', type: 'spki' })
      .toString('base64'),
    signCount: 0,
    environment: 'production',
    createdAt: Math.floor(T0_MS / 1000),
  };
  env.store.devices.set(keyId, record);
  return { keyId, privateKey, record };
}

export function assertionFor(
  device: TestDevice,
  body: string,
  options: { counter: number; signedBody?: string; appId?: string },
) {
  const data = authData({ appId: options.appId, counter: options.counter });
  const nonce = sha256(data, sha256(Buffer.from(options.signedBody ?? body)));
  const signature = sign('sha256', nonce, device.privateKey);
  return cborMap([
    ['signature', signature],
    ['authenticatorData', data],
  ]).toString('base64');
}

export function newChallenge(env: TestEnv): string {
  const challenge = randomBytes(32).toString('base64url');
  void env.store.putChallenge(challenge, Math.floor(env.clock.ms / 1000) + 300);
  return challenge;
}

export function signedEvent(
  env: TestEnv,
  device: TestDevice,
  routeKey: string,
  payload: Record<string, unknown>,
  options: {
    counter: number;
    challenge?: string;
    signedBody?: string;
  },
): HttpApiEvent {
  const body = JSON.stringify({
    challenge: options.challenge ?? newChallenge(env),
    ...payload,
  });
  return {
    routeKey,
    headers: {
      'x-tr-key-id': device.keyId,
      'x-tr-assertion': assertionFor(device, body, options),
    },
    body,
  };
}

export const SHA = Buffer.alloc(32, 9).toString('base64');

export function json(result: { body: string }) {
  return JSON.parse(result.body) as Record<string, unknown>;
}
