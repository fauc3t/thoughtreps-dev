import { CborError, decodeCbor } from './cbor.js';

const hex = (value: string) => Uint8Array.from(Buffer.from(value, 'hex'));

describe('decodeCbor', () => {
  it('decodes integers, strings, booleans and null', () => {
    expect(decodeCbor(hex('00'))).toBe(0);
    expect(decodeCbor(hex('1864'))).toBe(100);
    expect(decodeCbor(hex('3863'))).toBe(-100);
    expect(decodeCbor(hex('6161'))).toBe('a');
    expect(decodeCbor(hex('f5'))).toBe(true);
    expect(decodeCbor(hex('f6'))).toBe(null);
  });

  it('decodes byte strings, arrays and maps', () => {
    expect(decodeCbor(hex('43010203'))).toEqual(Uint8Array.from([1, 2, 3]));
    expect(decodeCbor(hex('820102'))).toEqual([1, 2]);
    const map = decodeCbor(hex('a1616101'));
    expect(map).toBeInstanceOf(Map);
    expect((map as Map<unknown, unknown>).get('a')).toBe(1);
  });

  it('rejects trailing bytes, truncation and unsupported types', () => {
    expect(() => decodeCbor(hex('0000'))).toThrow(CborError);
    expect(() => decodeCbor(hex('4301'))).toThrow(CborError);
    expect(() => decodeCbor(hex('fa3f800000'))).toThrow(CborError); // float
    expect(() => decodeCbor(hex('c001'))).toThrow(CborError); // tag
    expect(() => decodeCbor(hex('5fff'))).toThrow(CborError); // indefinite
  });

  it('does not allocate for absurd declared lengths', () => {
    expect(() => decodeCbor(hex('9affffffff'))).toThrow(CborError);
    expect(() => decodeCbor(hex('5affffffff'))).toThrow(CborError);
  });

  it('bounds nesting depth', () => {
    const deep = Buffer.concat([Buffer.alloc(20, 0x81), Buffer.from([0x00])]);
    expect(() => decodeCbor(deep)).toThrow(CborError);
  });
});
