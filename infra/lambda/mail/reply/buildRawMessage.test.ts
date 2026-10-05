import { buildRawMessage, type OriginalMessage } from './buildRawMessage.js';

function baseOriginal(
  overrides: Partial<OriginalMessage> = {},
): OriginalMessage {
  return {
    messageId: '<orig-1@example.test>',
    references: null,
    subject: 'Hello there',
    from: { address: 'sender@example.test', name: 'Sender' },
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

function body(raw: Uint8Array): string {
  const text = Buffer.from(raw).toString('utf-8');
  const [, ...rest] = text.split('\r\n\r\n');
  const encoded = rest.join('\r\n\r\n').split('\r\n').join('');
  return Buffer.from(encoded, 'base64').toString('utf-8');
}

describe('buildRawMessage', () => {
  it('adds a Re: prefix when the original subject lacks one', () => {
    const { raw } = buildRawMessage(
      baseOriginal({ subject: 'Hello there' }),
      'reply body',
      'hello@example.test',
    );
    expect(headers(raw).Subject).toBe('Re: Hello there');
  });

  it('does not double-prefix a subject that already starts with Re:', () => {
    const { raw } = buildRawMessage(
      baseOriginal({ subject: 'Re: Re: X' }),
      'reply body',
      'hello@example.test',
    );
    expect(headers(raw).Subject).toBe('Re: Re: X');
  });

  it('RFC 2047-encodes a non-ASCII subject', () => {
    const { raw } = buildRawMessage(
      baseOriginal({ subject: 'Café ☕' }),
      'reply body',
      'hello@example.test',
    );
    const subject = headers(raw).Subject;
    expect(subject).toMatch(/^=\?UTF-8\?B\?.+\?=$/);
    const encoded = subject.slice('=?UTF-8?B?'.length, -'?='.length);
    expect(Buffer.from(encoded, 'base64').toString('utf-8')).toBe(
      'Re: Café ☕',
    );
  });

  it('leaves a plain-ASCII subject unencoded', () => {
    const { raw } = buildRawMessage(
      baseOriginal({ subject: 'Plain subject' }),
      'reply body',
      'hello@example.test',
    );
    expect(headers(raw).Subject).toBe('Re: Plain subject');
  });

  it('round-trips a non-ASCII body through base64 with CRLF line wrapping', () => {
    const replyBody = 'Thanks — “great” café ☕ 😀 '.repeat(10);
    const { raw } = buildRawMessage(
      baseOriginal(),
      replyBody,
      'hello@example.test',
    );
    expect(headers(raw)['Content-Transfer-Encoding']).toBe('base64');
    expect(body(raw)).toBe(replyBody);

    const text = Buffer.from(raw).toString('utf-8');
    const [, ...rest] = text.split('\r\n\r\n');
    const bodyLines = rest.join('\r\n\r\n').split('\r\n');
    for (const line of bodyLines) {
      expect(line.length).toBeLessThanOrEqual(76);
    }
  });

  it('appends the original messageId onto an existing References value', () => {
    const { raw } = buildRawMessage(
      baseOriginal({
        messageId: '<orig-2@example.test>',
        references: '<orig-0@example.test> <orig-1@example.test>',
      }),
      'reply body',
      'hello@example.test',
    );
    expect(headers(raw).References).toBe(
      '<orig-0@example.test> <orig-1@example.test> <orig-2@example.test>',
    );
  });

  it('falls back to just the messageId when the original had no References header', () => {
    const { raw } = buildRawMessage(
      baseOriginal({ messageId: '<orig-2@example.test>', references: null }),
      'reply body',
      'hello@example.test',
    );
    expect(headers(raw).References).toBe('<orig-2@example.test>');
  });

  it('throws when the original message has no From address', () => {
    expect(() =>
      buildRawMessage(
        baseOriginal({ from: null }),
        'reply body',
        'hello@example.test',
      ),
    ).toThrow();

    expect(() =>
      buildRawMessage(
        baseOriginal({ from: { address: null } }),
        'reply body',
        'hello@example.test',
      ),
    ).toThrow();
  });

  // Regression test for a real, verified vulnerability: postal-mime's RFC
  // 2047 decode-words() on the *original* message's headers can produce a
  // decoded string containing a literal embedded CRLF, which still passes
  // isAscii() (CR/LF are <= 0x7f) and would — without sanitizeHeaderValue —
  // be written straight into a header line, injecting arbitrary extra
  // headers (a spoofed Bcc:, a second To:, etc.) into the outbound message.
  it('neutralizes an embedded CRLF in the original subject/messageId/references instead of letting it inject extra header lines', () => {
    const injectedSubject = 'Hi\r\nBcc: attacker@evil.test\r\nX-Injected: yes';
    const injectedMessageId = '<orig\r\nX-Injected-Mid: yes@evil.test>';
    const injectedReferences = '<ref\r\nX-Injected-Ref: yes@evil.test>';

    const { raw } = buildRawMessage(
      baseOriginal({
        subject: injectedSubject,
        messageId: injectedMessageId,
        references: injectedReferences,
      }),
      'reply body',
      'hello@example.test',
    );

    // The injected text ("Bcc:", "X-Injected...") is expected to still be
    // present *as literal characters inside the Subject/In-Reply-To/
    // References values themselves* — sanitization neutralizes the CRLF
    // that would otherwise turn it into a real separate header, it doesn't
    // (and shouldn't need to) scrub the word "Bcc" out of legitimate-
    // looking text. So the actual security property to assert is: no line
    // in the header block is itself an injected header — every line starts
    // with one of the header names this function is actually supposed to
    // emit, and there are exactly as many header lines as a non-malicious
    // reply would produce (no extra lines smuggled in).
    const text = Buffer.from(raw).toString('utf-8');
    const [headerBlock] = text.split('\r\n\r\n');
    const headerLines = headerBlock.split('\r\n');

    const nonMaliciousHeaderLines = Buffer.from(
      buildRawMessage(baseOriginal(), 'reply body', 'hello@example.test').raw,
    )
      .toString('utf-8')
      .split('\r\n\r\n')[0]
      .split('\r\n').length;
    expect(headerLines).toHaveLength(nonMaliciousHeaderLines);

    for (const line of headerLines) {
      expect(line).toMatch(
        /^(To|From|Subject|In-Reply-To|References|MIME-Version|Content-Type|Content-Transfer-Encoding): /,
      );
    }
    expect(headerLines.some((line) => line.startsWith('Bcc:'))).toBe(false);
    expect(headerLines.some((line) => line.startsWith('X-Injected'))).toBe(
      false,
    );
  });
});
