import {
  X509Certificate,
  createHash,
  createPublicKey,
  timingSafeEqual,
  verify,
} from 'node:crypto';
import { APPLE_APP_ATTESTATION_ROOT_CA_PEM } from './apple-root.js';
import { decodeCbor } from './cbor.js';

// Server side of Apple's "Validating apps that connect to your server":
// https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server

export class AttestationError extends Error {}
export class AssertionError extends Error {}

// `appattest` + 7 zero bytes. Development builds use `appattestdevelop`
// and must never be accepted: their keys aren't bound to a genuine App
// Store/TestFlight build.
const PRODUCTION_AAGUID = Buffer.concat([
  Buffer.from('appattest', 'ascii'),
  Buffer.alloc(7),
]);

const NONCE_EXTENSION_OID = Buffer.from([
  0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02,
]);

const CLOCK_SKEW_MS = 60_000;

const sha256 = (...parts: Uint8Array[]) =>
  createHash('sha256').update(Buffer.concat(parts)).digest();

const equal = (a: Uint8Array, b: Uint8Array) =>
  a.length === b.length && timingSafeEqual(a, b);

function asMap(value: unknown, label: string): Map<unknown, unknown> {
  if (!(value instanceof Map)) throw new AttestationError(`${label} not a map`);
  return value;
}

function asBytes(value: unknown, label: string): Buffer {
  if (!(value instanceof Uint8Array)) {
    throw new AttestationError(`${label} not bytes`);
  }
  return Buffer.from(value);
}

// The client hashes the challenge string's UTF-8 bytes (the base64url text
// exactly as served), not the decoded 32 bytes.
export function computeAttestationNonce(
  authData: Uint8Array,
  challenge: string,
): Buffer {
  return sha256(authData, sha256(Buffer.from(challenge, 'utf8')));
}

export interface AttestedAuthData {
  counter: number;
}

export function checkAttestedAuthData(
  authData: Buffer,
  expected: { appId: string; keyId: Buffer },
): AttestedAuthData {
  // rpIdHash(32) flags(1) counter(4) aaguid(16) credentialIdLength(2)
  if (authData.length < 55) throw new AttestationError('authData too short');
  const rpIdHash = authData.subarray(0, 32);
  const counter = authData.readUInt32BE(33);
  const aaguid = authData.subarray(37, 53);
  const credentialIdLength = authData.readUInt16BE(53);
  const credentialId = authData.subarray(55, 55 + credentialIdLength);

  if (!equal(rpIdHash, sha256(Buffer.from(expected.appId, 'utf8')))) {
    throw new AttestationError('rpIdHash mismatch');
  }
  if (counter !== 0) throw new AttestationError('counter not zero');
  if (!equal(aaguid, PRODUCTION_AAGUID)) {
    throw new AttestationError('not a production attestation');
  }
  if (
    credentialId.length !== credentialIdLength ||
    !equal(credentialId, expected.keyId)
  ) {
    throw new AttestationError('credentialId mismatch');
  }
  return { counter };
}

function readTlv(buf: Buffer, offset: number) {
  if (offset + 2 > buf.length) throw new AttestationError('bad DER');
  const tag = buf[offset];
  let length = buf[offset + 1];
  let start = offset + 2;
  if (length & 0x80) {
    const lengthBytes = length & 0x7f;
    if (
      lengthBytes < 1 ||
      lengthBytes > 3 ||
      start + lengthBytes > buf.length
    ) {
      throw new AttestationError('bad DER');
    }
    length = 0;
    for (let i = 0; i < lengthBytes; i++) {
      length = (length << 8) | buf[start + i];
    }
    start += lengthBytes;
  }
  if (start + length > buf.length) throw new AttestationError('bad DER');
  return { tag, start, end: start + length };
}

// Extension ::= SEQUENCE { extnID OID, critical BOOLEAN OPTIONAL, extnValue
// OCTET STRING }, with extnValue = SEQUENCE { [1] { OCTET STRING nonce } }.
// Node exposes no extension API, so find the OID in the DER and walk from
// there. The leaf is only trusted after chain validation, so a stray byte
// match elsewhere in the certificate can't be used to forge a nonce.
export function extractNonceFromCertificate(certDer: Buffer): Buffer {
  const at = certDer.indexOf(NONCE_EXTENSION_OID);
  if (at < 0) throw new AttestationError('nonce extension missing');
  let tlv = readTlv(certDer, at + NONCE_EXTENSION_OID.length);
  if (tlv.tag === 0x01) tlv = readTlv(certDer, tlv.end);
  if (tlv.tag !== 0x04) throw new AttestationError('bad nonce extension');
  const sequence = readTlv(certDer, tlv.start);
  const context = readTlv(certDer, sequence.start);
  const octets = readTlv(certDer, context.start);
  if (sequence.tag !== 0x30 || context.tag !== 0xa1 || octets.tag !== 0x04) {
    throw new AttestationError('bad nonce extension');
  }
  return certDer.subarray(octets.start, octets.end);
}

// The App Attest keyId: SHA-256 of the uncompressed X9.62 point (0x04 || X || Y).
export function keyIdOfCertificate(cert: X509Certificate): Buffer {
  const jwk = cert.publicKey.export({ format: 'jwk' });
  if (jwk.kty !== 'EC' || jwk.crv !== 'P-256' || !jwk.x || !jwk.y) {
    throw new AttestationError('leaf key is not P-256');
  }
  return sha256(
    Buffer.from([0x04]),
    Buffer.from(jwk.x, 'base64url'),
    Buffer.from(jwk.y, 'base64url'),
  );
}

export function verifyCertificateChain(
  x5c: Buffer[],
  now: Date,
  rootPem: string = APPLE_APP_ATTESTATION_ROOT_CA_PEM,
): X509Certificate {
  if (x5c.length !== 2) throw new AttestationError('unexpected chain length');
  let leaf: X509Certificate;
  let intermediate: X509Certificate;
  let root: X509Certificate;
  try {
    leaf = new X509Certificate(x5c[0]);
    intermediate = new X509Certificate(x5c[1]);
    root = new X509Certificate(rootPem);
  } catch {
    throw new AttestationError('unparseable certificate');
  }

  const t = now.getTime();
  for (const cert of [leaf, intermediate, root]) {
    if (
      t < new Date(cert.validFrom).getTime() - CLOCK_SKEW_MS ||
      t > new Date(cert.validTo).getTime() + CLOCK_SKEW_MS
    ) {
      throw new AttestationError('certificate outside validity period');
    }
  }
  const linked =
    intermediate.ca &&
    leaf.checkIssued(intermediate) &&
    leaf.verify(intermediate.publicKey) &&
    intermediate.checkIssued(root) &&
    intermediate.verify(root.publicKey);
  if (!linked) throw new AttestationError('chain does not reach Apple root');
  return leaf;
}

export interface VerifiedAttestation {
  publicKeySpki: Buffer;
}

export function verifyAttestation(input: {
  attestation: Buffer;
  challenge: string;
  keyId: string;
  appId: string;
  now: Date;
  rootPem?: string;
}): VerifiedAttestation {
  let decoded: Map<unknown, unknown>;
  try {
    decoded = asMap(decodeCbor(input.attestation), 'attestation');
  } catch (err) {
    if (err instanceof AttestationError) throw err;
    throw new AttestationError('malformed CBOR');
  }
  if (decoded.get('fmt') !== 'apple-appattest') {
    throw new AttestationError('unexpected fmt');
  }
  const attStmt = asMap(decoded.get('attStmt'), 'attStmt');
  const authData = asBytes(decoded.get('authData'), 'authData');
  const x5c = attStmt.get('x5c');
  if (!Array.isArray(x5c)) throw new AttestationError('x5c missing');

  const leaf = verifyCertificateChain(
    x5c.map((cert) => asBytes(cert, 'x5c entry')),
    input.now,
    input.rootPem,
  );

  const nonce = computeAttestationNonce(authData, input.challenge);
  if (!equal(extractNonceFromCertificate(leaf.raw), nonce)) {
    throw new AttestationError('nonce mismatch');
  }

  const keyId = Buffer.from(input.keyId, 'base64');
  if (!equal(keyIdOfCertificate(leaf), keyId)) {
    throw new AttestationError('keyId does not match certificate key');
  }

  checkAttestedAuthData(authData, { appId: input.appId, keyId });

  return {
    publicKeySpki: leaf.publicKey.export({ format: 'der', type: 'spki' }),
  };
}

// Returns the assertion's counter; the caller must persist it atomically
// (only if it still equals the stored value) so a replayed assertion loses.
export function verifyAssertion(input: {
  assertion: Buffer;
  body: Buffer;
  publicKeySpki: Buffer;
  storedSignCount: number;
  appId: string;
}): number {
  try {
    const decoded = decodeCbor(input.assertion);
    if (!(decoded instanceof Map)) throw new AssertionError('not a map');
    const signature = decoded.get('signature');
    const authenticatorData = decoded.get('authenticatorData');
    if (
      !(signature instanceof Uint8Array) ||
      !(authenticatorData instanceof Uint8Array)
    ) {
      throw new AssertionError('missing fields');
    }
    const authData = Buffer.from(authenticatorData);
    if (authData.length < 37) throw new AssertionError('authData too short');

    if (
      !equal(authData.subarray(0, 32), sha256(Buffer.from(input.appId, 'utf8')))
    ) {
      throw new AssertionError('rpIdHash mismatch');
    }

    // Apple signs the nonce with ECDSA-SHA256, i.e. the nonce is hashed
    // once more as the message.
    const nonce = sha256(authData, sha256(input.body));
    const valid = verify(
      'sha256',
      nonce,
      {
        key: createPublicKey({
          key: input.publicKeySpki,
          format: 'der',
          type: 'spki',
        }),
        dsaEncoding: 'der',
      },
      signature,
    );
    if (!valid) throw new AssertionError('bad signature');

    const counter = authData.readUInt32BE(33);
    if (counter <= input.storedSignCount) {
      throw new AssertionError('counter not increasing');
    }
    return counter;
  } catch (err) {
    if (err instanceof AssertionError) throw err;
    throw new AssertionError('malformed assertion');
  }
}
