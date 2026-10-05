// @vitest-environment node
import { describe, expect, it } from 'vitest';
import { bytesToBase64url, encryptExport, makeZip } from '../test/fixture';
import { decryptExport, FormatError, sha256Base64 } from './crypto';
import { parseLink } from './link';
import { exportFilename } from './save';
import { hasExportMimetype } from './zip';

const ID = 'AAAAAAAAAAAAAAAAAAAAAA';
const KEY = 'A'.repeat(43);

describe('parseLink', () => {
  it('accepts a well-formed link', () => {
    expect(parseLink(`/x/${ID}`, `#${KEY}`)).toEqual({
      ok: true,
      id: ID,
      key: KEY,
    });
  });

  it.each([
    ['/', `#${KEY}`],
    ['/x/short', `#${KEY}`],
    [`/x/${ID}/extra`, `#${KEY}`],
    [`/x/${ID}+`, `#${KEY}`],
  ])('rejects a bad id in %s', (path, hash) => {
    expect(parseLink(path, hash)).toEqual({ ok: false, reason: 'bad_id' });
  });

  it.each(['', '#', `#${'A'.repeat(42)}`, `#${'A'.repeat(44)}`, `#${'+'.repeat(43)}`])(
    'rejects bad key %j',
    (hash) => {
      expect(parseLink(`/x/${ID}`, hash)).toEqual({
        ok: false,
        reason: 'bad_key',
      });
    },
  );
});

describe('decryptExport', () => {
  it('round-trips a TRB1 file', async () => {
    const zip = makeZip();
    const { file, key } = await encryptExport(zip);
    expect(new Uint8Array(await decryptExport(file, key))).toEqual(zip);
  });

  it('rejects a bad prefix', async () => {
    const { file, key } = await encryptExport(makeZip());
    file[0] = 0x58;
    await expect(decryptExport(file, key)).rejects.toBeInstanceOf(FormatError);
  });

  it('rejects a truncated file', async () => {
    const { key } = await encryptExport(makeZip());
    const short = new TextEncoder().encode('TRB1 too short');
    await expect(decryptExport(short, key)).rejects.toBeInstanceOf(FormatError);
  });

  it('rejects a corrupted tag', async () => {
    const { file, key } = await encryptExport(makeZip());
    file[file.length - 1] ^= 1;
    await expect(decryptExport(file, key)).rejects.toThrow();
  });

  it('rejects the wrong key', async () => {
    const { file } = await encryptExport(makeZip());
    const wrong = bytesToBase64url(crypto.getRandomValues(new Uint8Array(32)));
    await expect(decryptExport(file, wrong)).rejects.toThrow();
  });
});

describe('sha256Base64', () => {
  it('matches the known digest of "abc"', async () => {
    expect(await sha256Base64(new TextEncoder().encode('abc'))).toBe(
      'ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=',
    );
  });
});

describe('hasExportMimetype', () => {
  it('accepts a stored mimetype entry', () => {
    expect(hasExportMimetype(makeZip())).toBe(true);
  });

  it('rejects an extra field, like the Swift importer', () => {
    expect(hasExportMimetype(makeZip({ extra: 5 }))).toBe(false);
  });

  it('rejects a compressed method', () => {
    const zip = makeZip();
    zip[8] = 8;
    expect(hasExportMimetype(zip)).toBe(false);
  });

  it('rejects sizes that do not match the value length', () => {
    const zip = makeZip();
    new DataView(zip.buffer).setUint32(22, 7, true);
    expect(hasExportMimetype(zip)).toBe(false);
  });

  it('accepts a data descriptor only when another entry follows', () => {
    expect(hasExportMimetype(makeZip({ descriptorNext: 0x04034b50 }))).toBe(
      true,
    );
    expect(hasExportMimetype(makeZip({ descriptorNext: 0 }))).toBe(false);
  });

  it('rejects another first entry', () => {
    expect(hasExportMimetype(makeZip({ name: 'manifest' }))).toBe(false);
  });

  it('rejects a wrong mimetype value', () => {
    const zip = makeZip();
    zip[zip.length - 9] ^= 1;
    expect(hasExportMimetype(zip)).toBe(false);
  });

  it('rejects non-zip and tiny input', () => {
    expect(hasExportMimetype(new Uint8Array(100))).toBe(false);
    expect(hasExportMimetype(new Uint8Array(4))).toBe(false);
  });
});

describe('exportFilename', () => {
  it('uses the local date', () => {
    expect(exportFilename(new Date(2026, 9, 5, 12))).toBe(
      'ThoughtReps-export-2026-10-05.thoughtreps',
    );
  });
});
