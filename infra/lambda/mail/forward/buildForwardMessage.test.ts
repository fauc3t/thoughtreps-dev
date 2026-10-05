import {
  buildForwardMessage,
  type OriginalMessage,
} from './buildForwardMessage.js';

function baseOriginal(
  overrides: Partial<OriginalMessage> = {},
): OriginalMessage {
  return {
    subject: 'Hello there',
    ...overrides,
  };
}

function headers(raw: Uint8Array): Record<string, string> {
  const text = Buffer.from(raw).toString('utf-8');
  const [headerBlock] = text.split('\r\n\r\n');
  const result: Record<string, string> = {};
  for (const line of headerBlock.split('\r\n')) {
    const idx = line.indexOf(': ');
    if (idx === -1) continue;
    result[line.slice(0, idx)] = line.slice(idx + 2);
  }
  return result;
}

describe('buildForwardMessage', () => {
  it('sets To/From to the forwarding addresses', () => {
    const { raw } = buildForwardMessage(
      baseOriginal(),
      Buffer.from('original body', 'utf-8'),
      'hello@example.test',
      'me@example.test',
    );
    expect(headers(raw).From).toBe('hello@example.test');
    expect(headers(raw).To).toBe('me@example.test');
  });

  it('adds a Fwd: prefix when the original subject lacks one', () => {
    const { raw } = buildForwardMessage(
      baseOriginal({ subject: 'Hello there' }),
      Buffer.from('original body', 'utf-8'),
      'hello@example.test',
      'me@example.test',
    );
    expect(headers(raw).Subject).toBe('Fwd: Hello there');
  });

  it('does not double-prefix a subject that already starts with Fwd:', () => {
    const { raw } = buildForwardMessage(
      baseOriginal({ subject: 'Fwd: X' }),
      Buffer.from('original body', 'utf-8'),
      'hello@example.test',
      'me@example.test',
    );
    expect(headers(raw).Subject).toBe('Fwd: X');
  });

  it('is case-insensitive when checking for an existing Fwd: prefix', () => {
    const { raw } = buildForwardMessage(
      baseOriginal({ subject: 'FWD: X' }),
      Buffer.from('original body', 'utf-8'),
      'hello@example.test',
      'me@example.test',
    );
    expect(headers(raw).Subject).toBe('FWD: X');
  });

  it('includes the original raw bytes byte-for-byte, unmodified, within the message/rfc822 part', () => {
    // Deliberately includes bytes that are not valid UTF-8 on their own
    // (0xff, 0xfe) plus a CRLF sequence and multipart-boundary-looking text,
    // to confirm the attachment is carried through as opaque bytes rather
    // than being decoded/re-encoded/mangled in any way.
    const rawOriginalBytes = Buffer.concat([
      Buffer.from(
        'From: sender@example.test\r\nSubject: Original\r\n\r\nBody text\r\n',
        'utf-8',
      ),
      Buffer.from([0xff, 0xfe, 0x00, 0x41]),
    ]);

    const { raw } = buildForwardMessage(
      baseOriginal(),
      rawOriginalBytes,
      'hello@example.test',
      'me@example.test',
    );

    const rawBuffer = Buffer.from(raw);
    const index = rawBuffer.indexOf(rawOriginalBytes);
    expect(index).toBeGreaterThan(-1);
    expect(
      rawBuffer
        .subarray(index, index + rawOriginalBytes.length)
        .equals(rawOriginalBytes),
    ).toBe(true);
  });

  it('declares the attachment part as message/rfc822 with 8bit transfer encoding', () => {
    const { raw } = buildForwardMessage(
      baseOriginal(),
      Buffer.from('original body', 'utf-8'),
      'hello@example.test',
      'me@example.test',
    );
    const text = Buffer.from(raw).toString('latin1');
    expect(text).toMatch(/Content-Type: message\/rfc822\r\n/);
    expect(text).toMatch(
      /Content-Type: message\/rfc822\r\nContent-Transfer-Encoding: 8bit\r\n/,
    );
  });

  // Regression test for the same attack class buildRawMessage.test.ts's own
  // regression test covers: postal-mime's RFC 2047 decode-words() on the
  // *original* message's Subject can produce a decoded string containing a
  // literal embedded CRLF, which would — without sanitizeHeaderValue —
  // inject arbitrary extra header lines into this outbound forward.
  it('neutralizes an embedded CRLF in the original subject instead of letting it inject extra header lines', () => {
    const injectedSubject = 'Hi\r\nBcc: attacker@evil.test\r\nX-Injected: yes';

    const { raw } = buildForwardMessage(
      baseOriginal({ subject: injectedSubject }),
      Buffer.from('original body', 'utf-8'),
      'hello@example.test',
      'me@example.test',
    );

    const text = Buffer.from(raw).toString('utf-8');
    const [headerBlock] = text.split('\r\n\r\n');
    const headerLines = headerBlock.split('\r\n');

    const nonMaliciousHeaderLines = Buffer.from(
      buildForwardMessage(
        baseOriginal(),
        Buffer.from('original body', 'utf-8'),
        'hello@example.test',
        'me@example.test',
      ).raw,
    )
      .toString('utf-8')
      .split('\r\n\r\n')[0]
      .split('\r\n').length;
    expect(headerLines).toHaveLength(nonMaliciousHeaderLines);

    for (const line of headerLines) {
      expect(line).toMatch(/^(MIME-Version|From|To|Subject|Content-Type): /);
    }
    expect(headerLines.some((line) => line.startsWith('Bcc:'))).toBe(false);
    expect(headerLines.some((line) => line.startsWith('X-Injected'))).toBe(
      false,
    );
  });
});
