const MIMETYPE_NAME = new TextEncoder().encode('mimetype');
const MIMETYPE_VALUE = new TextEncoder().encode(
  'application/vnd.thoughtreps.export+zip',
);
const LOCAL_HEADER_SIGNATURE = 0x04034b50;
const STORED = 0;
const DATA_DESCRIPTOR_FLAG = 0x0008;
const HEADER_LENGTH = 30;

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

// Mirrors the Swift importer (BackupImporter.hasSignature): the first entry is
// a stored `mimetype` with an 8-byte name, no extra field and the exact value.
// Sizes must be real and equal to the value length; with a data descriptor
// (sizes unknown in the header) the entry must be followed by another local
// header instead.
export function hasExportMimetype(zip: Uint8Array): boolean {
  if (zip.length < HEADER_LENGTH) return false;
  const view = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);
  if (view.getUint32(0, true) !== LOCAL_HEADER_SIGNATURE) return false;
  if (view.getUint16(8, true) !== STORED) return false;
  if (view.getUint16(26, true) !== MIMETYPE_NAME.length) return false;
  if (view.getUint16(28, true) !== 0) return false;

  const nameEnd = HEADER_LENGTH + MIMETYPE_NAME.length;
  if (!bytesEqual(zip.subarray(HEADER_LENGTH, nameEnd), MIMETYPE_NAME)) {
    return false;
  }
  const dataEnd = nameEnd + MIMETYPE_VALUE.length;
  if (!bytesEqual(zip.subarray(nameEnd, dataEnd), MIMETYPE_VALUE)) return false;

  const compressed = view.getUint32(18, true);
  const uncompressed = view.getUint32(22, true);
  if (view.getUint16(6, true) & DATA_DESCRIPTOR_FLAG) {
    const next = dataEnd + 16 <= zip.length ? view.getUint32(dataEnd + 16, true) : 0;
    const nextNoSig =
      dataEnd + 12 <= zip.length ? view.getUint32(dataEnd + 12, true) : 0;
    return (
      compressed === 0 &&
      uncompressed === 0 &&
      (next === LOCAL_HEADER_SIGNATURE || nextNoSig === LOCAL_HEADER_SIGNATURE)
    );
  }
  return (
    compressed === MIMETYPE_VALUE.length &&
    uncompressed === MIMETYPE_VALUE.length
  );
}
