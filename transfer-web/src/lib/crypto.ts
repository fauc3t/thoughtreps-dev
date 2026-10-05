const MAGIC = new TextEncoder().encode('TRB1');
const NONCE_LENGTH = 12;
const TAG_LENGTH = 16;
const HEADER_LENGTH = MAGIC.length + NONCE_LENGTH;

export class FormatError extends Error {}

export function base64urlToBytes(value: string): Uint8Array {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, '=');
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

export async function sha256Base64(data: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', data));
  return btoa(String.fromCharCode(...digest));
}

// Throws FormatError for a wrong prefix or a truncated file, and the
// WebCrypto OperationError for a wrong key or a tampered/corrupt file.
export async function decryptExport(
  file: Uint8Array,
  keyBase64url: string,
): Promise<ArrayBuffer> {
  const hasMagic = MAGIC.every((b, i) => file[i] === b);
  if (!hasMagic || file.length < HEADER_LENGTH + TAG_LENGTH) {
    throw new FormatError('Not a Thought Reps export file');
  }
  const key = await crypto.subtle.importKey(
    'raw',
    base64urlToBytes(keyBase64url),
    'AES-GCM',
    false,
    ['decrypt'],
  );
  return crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: file.subarray(MAGIC.length, HEADER_LENGTH) },
    key,
    file.subarray(HEADER_LENGTH),
  );
}
