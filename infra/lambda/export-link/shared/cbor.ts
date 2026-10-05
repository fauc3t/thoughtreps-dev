// Just enough CBOR (RFC 8949) to read App Attest attestation and assertion
// objects: definite-length unsigned/negative ints, byte/text strings, arrays,
// maps, booleans and null. Anything else (tags, floats, indefinite lengths)
// is rejected rather than half-supported. Bounded depth and length checks
// keep attacker-controlled input from allocating or recursing unboundedly.

export type CborValue =
  | number
  | string
  | boolean
  | null
  | Uint8Array
  | CborValue[]
  | Map<CborValue, CborValue>;

const MAX_DEPTH = 8;

export class CborError extends Error {}

class Reader {
  offset = 0;
  constructor(readonly bytes: Uint8Array) {}

  take(length: number): Uint8Array {
    if (length > this.bytes.length - this.offset) {
      throw new CborError('truncated');
    }
    const out = this.bytes.subarray(this.offset, this.offset + length);
    this.offset += length;
    return out;
  }
}

function readLength(reader: Reader, info: number): number {
  if (info < 24) return info;
  const size =
    info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : info === 27 ? 8 : 0;
  if (size === 0) throw new CborError('unsupported length encoding');
  const raw = reader.take(size);
  let value = 0n;
  for (const byte of raw) value = (value << 8n) | BigInt(byte);
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new CborError('integer too large');
  }
  return Number(value);
}

function readValue(reader: Reader, depth: number): CborValue {
  if (depth > MAX_DEPTH) throw new CborError('too deep');
  const [initial] = reader.take(1);
  const major = initial >> 5;
  const info = initial & 0x1f;

  switch (major) {
    case 0:
      return readLength(reader, info);
    case 1:
      return -1 - readLength(reader, info);
    case 2:
      return reader.take(readLength(reader, info)).slice();
    case 3:
      return new TextDecoder('utf-8', { fatal: true }).decode(
        reader.take(readLength(reader, info)),
      );
    case 4: {
      const count = readLength(reader, info);
      if (count > reader.bytes.length - reader.offset) {
        throw new CborError('truncated');
      }
      const items: CborValue[] = [];
      for (let i = 0; i < count; i++) items.push(readValue(reader, depth + 1));
      return items;
    }
    case 5: {
      const count = readLength(reader, info);
      if (count > reader.bytes.length - reader.offset) {
        throw new CborError('truncated');
      }
      const map = new Map<CborValue, CborValue>();
      for (let i = 0; i < count; i++) {
        const key = readValue(reader, depth + 1);
        map.set(key, readValue(reader, depth + 1));
      }
      return map;
    }
    case 7:
      if (info === 20) return false;
      if (info === 21) return true;
      if (info === 22) return null;
      throw new CborError('unsupported simple value');
    default:
      throw new CborError('unsupported major type');
  }
}

export function decodeCbor(bytes: Uint8Array): CborValue {
  const reader = new Reader(bytes);
  const value = readValue(reader, 0);
  if (reader.offset !== bytes.length) throw new CborError('trailing bytes');
  return value;
}
