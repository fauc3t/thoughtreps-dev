import { createHash } from 'node:crypto';
import {
  AssertionError,
  AttestationError,
  checkAttestedAuthData,
  computeAttestationNonce,
  extractNonceFromCertificate,
  verifyAssertion,
  verifyAttestation,
} from './appattest.js';
import {
  DEVELOPMENT_ATTESTATION,
  FIXTURE_APP_ID,
  FIXTURE_CHALLENGE,
  FIXTURE_ROOT_PEM,
  PRODUCTION_ATTESTATION,
} from './attestationFixture.js';
import {
  APP_ID,
  assertionFor,
  cborMap,
  makeEnv,
  registerTestDevice,
} from './testSupport.js';

const sha256 = (...parts: Uint8Array[]) =>
  createHash('sha256').update(Buffer.concat(parts)).digest();

describe('verifyAssertion', () => {
  const env = makeEnv();
  const device = registerTestDevice(env);
  const body = Buffer.from('{"hello":"world"}');
  const spki = Buffer.from(device.record.publicKey, 'base64');

  const verify = (
    assertion: string,
    overrides: { storedSignCount?: number; body?: Buffer; appId?: string } = {},
  ) =>
    verifyAssertion({
      assertion: Buffer.from(assertion, 'base64'),
      body: overrides.body ?? body,
      publicKeySpki: spki,
      storedSignCount: overrides.storedSignCount ?? 0,
      appId: overrides.appId ?? APP_ID,
    });

  it('accepts a valid assertion and returns its counter', () => {
    expect(verify(assertionFor(device, body.toString(), { counter: 1 }))).toBe(
      1,
    );
  });

  it('requires the counter to strictly increase', () => {
    const assertion = assertionFor(device, body.toString(), { counter: 5 });
    expect(verify(assertion, { storedSignCount: 4 })).toBe(5);
    expect(() => verify(assertion, { storedSignCount: 5 })).toThrow(
      AssertionError,
    );
    expect(() => verify(assertion, { storedSignCount: 9 })).toThrow(
      AssertionError,
    );
  });

  it('rejects a signature made over a different body than the one sent', () => {
    const assertion = assertionFor(device, body.toString(), {
      counter: 1,
      signedBody: '{"hello":"other"}',
    });
    expect(() => verify(assertion)).toThrow(AssertionError);
  });

  it('rejects a body that was altered after signing', () => {
    const assertion = assertionFor(device, body.toString(), { counter: 1 });
    expect(() =>
      verify(assertion, { body: Buffer.from('{"hello":"x"}') }),
    ).toThrow(AssertionError);
  });

  it('rejects an assertion for a different app id', () => {
    const assertion = assertionFor(device, body.toString(), {
      counter: 1,
      appId: 'OTHER.com.example.app',
    });
    expect(() => verify(assertion)).toThrow(AssertionError);
  });

  it('rejects a signature from a different key', () => {
    const other = registerTestDevice(env);
    const assertion = assertionFor(other, body.toString(), { counter: 1 });
    expect(() => verify(assertion)).toThrow(AssertionError);
  });

  it('rejects malformed CBOR and missing fields', () => {
    expect(() => verify('AAAA')).toThrow(AssertionError);
    expect(() =>
      verify(cborMap([['signature', Buffer.alloc(8)]]).toString('base64')),
    ).toThrow(AssertionError);
  });
});

describe('attestation pieces', () => {
  const keyId = sha256(Buffer.from('some public key'));

  function attestedAuthData(
    options: {
      appId?: string;
      counter?: number;
      aaguid?: string;
      credentialId?: Buffer;
    } = {},
  ) {
    const credentialId = options.credentialId ?? keyId;
    const out = Buffer.alloc(55 + credentialId.length);
    sha256(Buffer.from(options.appId ?? APP_ID)).copy(out, 0);
    out.writeUInt32BE(options.counter ?? 0, 33);
    Buffer.from(options.aaguid ?? 'appattest\0\0\0\0\0\0\0').copy(out, 37);
    out.writeUInt16BE(credentialId.length, 53);
    credentialId.copy(out, 55);
    return out;
  }

  const check = (authData: Buffer) =>
    checkAttestedAuthData(authData, { appId: APP_ID, keyId });

  it('accepts production authData', () => {
    expect(check(attestedAuthData())).toEqual({ counter: 0 });
  });

  it('rejects another app id (rpIdHash)', () => {
    expect(() => check(attestedAuthData({ appId: 'X.y.z' }))).toThrow(
      AttestationError,
    );
  });

  it('rejects a non-zero counter', () => {
    expect(() => check(attestedAuthData({ counter: 1 }))).toThrow(
      AttestationError,
    );
  });

  it('rejects the development aaguid', () => {
    expect(() =>
      check(attestedAuthData({ aaguid: 'appattestdevelop' })),
    ).toThrow(/production/);
  });

  it('rejects a credentialId that is not the keyId', () => {
    expect(() =>
      check(attestedAuthData({ credentialId: sha256(Buffer.from('other')) })),
    ).toThrow(AttestationError);
  });

  it('rejects truncated authData', () => {
    expect(() => check(Buffer.alloc(40))).toThrow(AttestationError);
  });

  it('computes the nonce as SHA256(authData || SHA256(challenge text))', () => {
    const authData = Buffer.from('auth data');
    expect(computeAttestationNonce(authData, 'abc')).toEqual(
      sha256(authData, sha256(Buffer.from('abc'))),
    );
  });

  it('reads the nonce out of the Apple extension', () => {
    const nonce = Buffer.alloc(32, 0xab);
    const oid = Buffer.from([
      0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02,
    ]);
    const value = Buffer.concat([
      Buffer.from([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20]),
      nonce,
    ]);
    const der = Buffer.concat([
      Buffer.from([0x30, 0x03, 0x01, 0x01, 0x00]),
      oid,
      Buffer.from([0x04, value.length]),
      value,
    ]);
    expect(extractNonceFromCertificate(der)).toEqual(nonce);
    expect(() =>
      extractNonceFromCertificate(Buffer.from([0x30, 0x00])),
    ).toThrow(AttestationError);
  });
});

// Chain validation against Apple's real root can't be exercised offline, so
// these run the whole path against a throwaway root of our own (see
// attestationFixture.ts) via the rootPem parameter.
describe('verifyAttestation (test root)', () => {
  const now = new Date();
  const base = {
    challenge: FIXTURE_CHALLENGE,
    appId: FIXTURE_APP_ID,
    now,
    rootPem: FIXTURE_ROOT_PEM,
  };
  const production = {
    ...base,
    attestation: Buffer.from(PRODUCTION_ATTESTATION.attestation, 'base64'),
    keyId: PRODUCTION_ATTESTATION.keyId,
  };

  it('accepts a well-formed production attestation and returns the leaf key', () => {
    expect(verifyAttestation(production).publicKeySpki.toString('base64')).toBe(
      PRODUCTION_ATTESTATION.publicKeySpki,
    );
  });

  it('rejects a chain that does not reach the configured root', () => {
    expect(() =>
      verifyAttestation({
        ...production,
        rootPem: undefined,
      }),
    ).toThrow(/Apple root/);
  });

  it('rejects the wrong challenge (nonce mismatch)', () => {
    expect(() =>
      verifyAttestation({ ...production, challenge: 'x'.repeat(43) }),
    ).toThrow(/nonce/);
  });

  it('rejects a keyId that is not the certificate key', () => {
    expect(() =>
      verifyAttestation({
        ...production,
        keyId: Buffer.alloc(32, 1).toString('base64'),
      }),
    ).toThrow(/keyId/);
  });

  it('rejects another app id', () => {
    expect(() =>
      verifyAttestation({ ...production, appId: 'OTHER.com.example.app' }),
    ).toThrow(/rpIdHash/);
  });

  it('rejects a development-environment attestation', () => {
    expect(() =>
      verifyAttestation({
        ...base,
        attestation: Buffer.from(DEVELOPMENT_ATTESTATION.attestation, 'base64'),
        keyId: DEVELOPMENT_ATTESTATION.keyId,
      }),
    ).toThrow(/production/);
  });

  it('rejects certificates outside their validity period', () => {
    expect(() =>
      verifyAttestation({ ...production, now: new Date('2300-01-01') }),
    ).toThrow(/validity/);
  });

  it('rejects garbage and wrong formats', () => {
    expect(() =>
      verifyAttestation({ ...production, attestation: Buffer.from('nope') }),
    ).toThrow(AttestationError);
    expect(() =>
      verifyAttestation({
        ...production,
        attestation: cborMap([['fmt', Buffer.from('x')]]),
      }),
    ).toThrow(AttestationError);
  });
});
