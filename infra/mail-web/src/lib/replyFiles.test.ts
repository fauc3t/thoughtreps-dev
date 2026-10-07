import { describe, expect, it } from 'vitest';
import { MAX_REPLY_BYTES, validateReplyFiles } from './attachments';

function file(name: string, size = 1): File {
  const f = new File(['x'], name);
  Object.defineProperty(f, 'size', { value: size });
  return f;
}

describe('validateReplyFiles', () => {
  it('accepts files within every limit', () => {
    expect(validateReplyFiles([file('a')], [file('b')])).toBeNull();
  });

  it('rejects more than 10 files', () => {
    const existing = Array.from({ length: 9 }, (_, i) => file(`f${i}`));
    expect(validateReplyFiles(existing, [file('x'), file('y')])).toMatch(
      /at most 10 files/,
    );
  });

  it('rejects a single file over 25 MiB', () => {
    expect(
      validateReplyFiles([], [file('big.bin', MAX_REPLY_BYTES + 1)]),
    ).toMatch(/big\.bin/);
  });

  it('rejects when the total would exceed 25 MiB', () => {
    expect(
      validateReplyFiles([file('a', MAX_REPLY_BYTES)], [file('b', 1)]),
    ).toMatch(/total/);
  });

  it('allows exactly 25 MiB', () => {
    expect(validateReplyFiles([], [file('a', MAX_REPLY_BYTES)])).toBeNull();
  });
});
