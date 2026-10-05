import { z } from 'zod';

// Encrypted file format (what the app uploads; the server never sees the key):
//   "TRB1" (4 bytes) + 12-byte nonce + ciphertext + 16-byte GCM tag
// i.e. CryptoKit's AES-256-GCM `SealedBox.combined` with a 4-byte prefix.
// The key is 32 bytes, base64url, in the link's URL fragment
// (https://transfer.thoughtreps.com/x/<exportLinkId>#<key>), which browsers
// never send to a server.

export const MAX_UPLOAD_BYTES = 100 * 1024 * 1024;
export const EXPORT_LINK_TTL_SECONDS = 24 * 60 * 60;

const b64url = (len: number) =>
  z.string().regex(new RegExp(`^[A-Za-z0-9_-]{${len}}$`));
export const ExportLinkId = b64url(22); // 16 random bytes
export const Challenge = b64url(43); // 32 random bytes, single use, 5 min
export const KeyId = z.base64().length(44); // App Attest keyId (SHA-256 of public key)
export const Sha256 = z.base64().length(44); // of the ciphertext
const IsoDate = z.iso.datetime();

export const ErrorCode = z.enum([
  'bad_request',
  'attestation_invalid',
  'assertion_invalid',
  'challenge_invalid',
  'rate_limited',
  'too_large',
  'not_found',
  'upload_mismatch',
  'used',
  'expired',
  'revoked',
]);
export const ErrorResponse = z.object({
  error: ErrorCode,
  message: z.string(),
});

export const AssertionHeaders = z.object({
  'x-tr-key-id': KeyId,
  'x-tr-assertion': z.base64().max(4096),
});
const Signed = z.object({ challenge: Challenge });

export const ChallengeResponse = z.object({
  challenge: Challenge,
  expiresAt: IsoDate,
});

export const RegisterDeviceRequest = z.strictObject({
  keyId: KeyId,
  attestation: z.base64().max(16_384),
  challenge: Challenge,
});
export const RegisterDeviceResponse = z.object({ registered: z.literal(true) });

export const CreateExportLinkRequest = Signed.extend({
  sizeBytes: z.int().positive().max(MAX_UPLOAD_BYTES),
  sha256: Sha256,
}).strict();
export const CreateExportLinkResponse = z.object({
  exportLinkId: ExportLinkId,
  replacedExportLinkId: ExportLinkId.nullable(),
  upload: z.object({
    method: z.literal('PUT'),
    url: z.url(),
    headers: z.record(z.string(), z.string()),
    expiresAt: IsoDate,
  }),
});
export const CompleteExportLinkRequest = Signed.extend({
  exportLinkId: ExportLinkId,
}).strict();
export const CurrentExportLinkRequest = Signed.strict();
export const RevokeExportLinkRequest = Signed.extend({
  exportLinkId: ExportLinkId,
}).strict();

export const ExportLinkSummary = z.object({
  exportLinkId: ExportLinkId,
  status: z.enum(['pending', 'ready']),
  sizeBytes: z.int(),
  createdAt: IsoDate,
  expiresAt: IsoDate,
});
export const CompleteExportLinkResponse = ExportLinkSummary;
export const CurrentExportLinkResponse = z.object({
  exportLink: ExportLinkSummary.nullable(),
});
export const RevokeExportLinkResponse = z.object({ revoked: z.literal(true) });

export const ExportLinkStatusResponse = z.discriminatedUnion('status', [
  z.object({
    status: z.literal('ready'),
    sizeBytes: z.int(),
    expiresAt: IsoDate,
  }),
  z.object({ status: z.literal('used') }),
  z.object({ status: z.literal('expired') }),
  z.object({ status: z.literal('revoked') }),
]);
export const ClaimExportLinkResponse = z.object({
  download: z.object({ url: z.url(), expiresAt: IsoDate }),
  sizeBytes: z.int(),
  sha256: Sha256,
});

const Epoch = z.int().nonnegative();
export const ExportLinkRecord = z.object({
  pk: z.templateLiteral(['EXPORT#', z.string()]),
  exportLinkId: ExportLinkId,
  keyId: KeyId,
  status: z.enum(['pending', 'ready', 'used', 'revoked', 'expired']),
  sizeBytes: z.int(),
  sha256: Sha256,
  createdAt: Epoch,
  expiresAt: Epoch,
  claimedAt: Epoch.optional(),
  objectDeletedAt: Epoch.optional(),
  sweep: z.literal('OPEN').optional(),
  sweepAt: Epoch.optional(),
  ttl: Epoch,
});
export const DeviceRecord = z.object({
  pk: z.templateLiteral(['DEVICE#', z.string()]),
  keyId: KeyId,
  publicKey: z.base64(),
  signCount: Epoch,
  environment: z.literal('production'),
  currentExportLinkId: ExportLinkId.optional(),
  createdAt: Epoch,
});
export const ChallengeRecord = z.object({
  pk: z.templateLiteral(['CHALLENGE#', z.string()]),
  ttl: Epoch,
});
export const RateRecord = z.object({
  pk: z.templateLiteral(['RATE#', z.string()]),
  count: z.int(),
  ttl: Epoch,
});

export type ExportLinkRecord = z.infer<typeof ExportLinkRecord>;
export type DeviceRecord = z.infer<typeof DeviceRecord>;
