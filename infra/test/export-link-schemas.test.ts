import {
  AssertionHeaders,
  Challenge,
  ClaimExportLinkResponse,
  CompleteExportLinkRequest,
  CreateExportLinkRequest,
  CurrentExportLinkRequest,
  ExportLinkId,
  ExportLinkRecord,
  ExportLinkStatusResponse,
  KeyId,
  MAX_UPLOAD_BYTES,
  RegisterDeviceRequest,
  Sha256,
} from '../lib/export-link/schemas.js';

const key = Buffer.alloc(32, 1).toString('base64');
const id = 'A'.repeat(22);
const challenge = 'B'.repeat(43);

describe('identifier schemas', () => {
  it('accepts correctly shaped ids', () => {
    expect(ExportLinkId.safeParse(id).success).toBe(true);
    expect(ExportLinkId.safeParse('a_-0'.repeat(5) + 'ab').success).toBe(true);
    expect(Challenge.safeParse(challenge).success).toBe(true);
    expect(KeyId.safeParse(key).success).toBe(true);
    expect(Sha256.safeParse(key).success).toBe(true);
  });

  it('rejects wrong lengths and characters', () => {
    expect(ExportLinkId.safeParse('A'.repeat(21)).success).toBe(false);
    expect(ExportLinkId.safeParse('A'.repeat(21) + '=').success).toBe(false);
    expect(ExportLinkId.safeParse('A'.repeat(21) + '/').success).toBe(false);
    expect(Challenge.safeParse('B'.repeat(44)).success).toBe(false);
    expect(KeyId.safeParse('short').success).toBe(false);
    expect(KeyId.safeParse('!'.repeat(44)).success).toBe(false);
  });
});

describe('request schemas', () => {
  it('accepts a valid create request and rejects bad sizes and unknown fields', () => {
    const ok = { challenge, sizeBytes: 10, sha256: key };
    expect(CreateExportLinkRequest.safeParse(ok).success).toBe(true);
    for (const bad of [
      { ...ok, sizeBytes: 0 },
      { ...ok, sizeBytes: -1 },
      { ...ok, sizeBytes: 1.5 },
      { ...ok, sizeBytes: MAX_UPLOAD_BYTES + 1 },
      { ...ok, extra: 1 },
      { challenge, sizeBytes: 10 },
    ]) {
      expect(CreateExportLinkRequest.safeParse(bad).success).toBe(false);
    }
    expect(
      CreateExportLinkRequest.safeParse({ ...ok, sizeBytes: MAX_UPLOAD_BYTES })
        .success,
    ).toBe(true);
  });

  it('is strict for complete, current and register', () => {
    expect(
      CompleteExportLinkRequest.safeParse({ challenge, exportLinkId: id })
        .success,
    ).toBe(true);
    expect(
      CompleteExportLinkRequest.safeParse({ challenge, exportLinkId: 'x' })
        .success,
    ).toBe(false);
    expect(CurrentExportLinkRequest.safeParse({ challenge }).success).toBe(
      true,
    );
    expect(
      CurrentExportLinkRequest.safeParse({ challenge, other: 1 }).success,
    ).toBe(false);
    expect(
      RegisterDeviceRequest.safeParse({
        keyId: key,
        attestation: 'AAAA',
        challenge,
      }).success,
    ).toBe(true);
    expect(
      RegisterDeviceRequest.safeParse({
        keyId: key,
        attestation: 'AAAA',
        challenge,
        x: 1,
      }).success,
    ).toBe(false);
  });

  it('bounds the assertion header', () => {
    expect(
      AssertionHeaders.safeParse({
        'x-tr-key-id': key,
        'x-tr-assertion': 'AAAA',
      }).success,
    ).toBe(true);
    expect(
      AssertionHeaders.safeParse({
        'x-tr-key-id': key,
        'x-tr-assertion': 'A'.repeat(4100),
      }).success,
    ).toBe(false);
  });
});

describe('response and record schemas', () => {
  it('discriminates the public status on `status`', () => {
    const expiresAt = new Date().toISOString();
    expect(
      ExportLinkStatusResponse.safeParse({
        status: 'ready',
        sizeBytes: 5,
        expiresAt,
      }).success,
    ).toBe(true);
    expect(ExportLinkStatusResponse.safeParse({ status: 'used' }).success).toBe(
      true,
    );
    expect(
      ExportLinkStatusResponse.safeParse({ status: 'ready' }).success,
    ).toBe(false);
    expect(
      ExportLinkStatusResponse.safeParse({ status: 'pending' }).success,
    ).toBe(false);
  });

  it('requires an absolute download URL on claim', () => {
    const expiresAt = new Date().toISOString();
    const base = { sizeBytes: 1, sha256: key };
    expect(
      ClaimExportLinkResponse.safeParse({
        ...base,
        download: { url: 'https://s3.test/x', expiresAt },
      }).success,
    ).toBe(true);
    expect(
      ClaimExportLinkResponse.safeParse({
        ...base,
        download: { url: 'not a url', expiresAt },
      }).success,
    ).toBe(false);
  });

  it('validates stored link records', () => {
    const record = {
      pk: `EXPORT#${id}`,
      exportLinkId: id,
      keyId: key,
      status: 'pending',
      sizeBytes: 1,
      sha256: key,
      createdAt: 1,
      expiresAt: 2,
      sweep: 'OPEN',
      sweepAt: 2,
      ttl: 3,
    };
    expect(ExportLinkRecord.safeParse(record).success).toBe(true);
    expect(
      ExportLinkRecord.safeParse({ ...record, pk: `X#${id}` }).success,
    ).toBe(false);
    expect(
      ExportLinkRecord.safeParse({ ...record, status: 'weird' }).success,
    ).toBe(false);
  });
});
