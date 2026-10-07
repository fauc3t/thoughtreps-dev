import {
  buildRawMessage,
  sanitizeContentType,
  type OriginalMessage,
  type OutgoingAttachment,
} from './buildRawMessage.js';

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

  it('emits the same single-part message byte-for-byte when attachments is empty', () => {
    const withoutArg = buildRawMessage(
      baseOriginal(),
      'reply body',
      'hello@example.test',
    );
    const withEmpty = buildRawMessage(
      baseOriginal(),
      'reply body',
      'hello@example.test',
      [],
    );
    expect(Buffer.from(withEmpty.raw).equals(Buffer.from(withoutArg.raw))).toBe(
      true,
    );
    expect(headers(withEmpty.raw)['Content-Type']).toBe(
      'text/plain; charset=UTF-8',
    );
  });
});

describe('buildRawMessage with attachments', () => {
  function build(
    attachments: OutgoingAttachment[],
    replyBody = 'reply body',
  ): { text: string; boundary: string } {
    const { raw } = buildRawMessage(
      baseOriginal(),
      replyBody,
      'hello@example.test',
      attachments,
    );
    const text = Buffer.from(raw).toString('utf-8');
    const boundary = /boundary="([^"]+)"/.exec(text)?.[1] ?? '';
    return { text, boundary };
  }

  function parts(text: string, boundary: string): string[] {
    return text
      .split(`--${boundary}`)
      .slice(1, -1)
      .map((part) => part.replace(/^\r\n/, '').replace(/\r\n$/, ''));
  }

  const file = (overrides: Partial<OutgoingAttachment> = {}) => ({
    filename: 'report.pdf',
    contentType: 'application/pdf',
    data: Buffer.from('hello attachment'),
    ...overrides,
  });

  it('builds multipart/mixed with a text part followed by one part per file', () => {
    const { text, boundary } = build([
      file(),
      file({ filename: 'b.txt', contentType: 'text/plain' }),
    ]);
    const topHeaders = text.split('\r\n\r\n')[0];
    expect(topHeaders).toContain(
      `Content-Type: multipart/mixed; boundary="${boundary}"`,
    );
    expect(topHeaders).not.toContain('Content-Transfer-Encoding');
    expect(text.endsWith(`\r\n--${boundary}--\r\n`)).toBe(true);

    const [textPart, first, second] = parts(text, boundary);
    expect(textPart).toContain('Content-Type: text/plain; charset=UTF-8');
    const textBody = textPart.split('\r\n\r\n')[1].split('\r\n').join('');
    expect(Buffer.from(textBody, 'base64').toString('utf-8')).toBe(
      'reply body',
    );

    expect(first).toContain('Content-Type: application/pdf; name="report.pdf"');
    expect(first).toContain(
      'Content-Disposition: attachment; filename="report.pdf"',
    );
    expect(first).toContain('Content-Transfer-Encoding: base64');
    const firstBody = first.split('\r\n\r\n')[1].split('\r\n').join('');
    expect(Buffer.from(firstBody, 'base64').toString()).toBe(
      'hello attachment',
    );
    expect(second).toContain('name="b.txt"');
  });

  it('allows an empty reply body', () => {
    const { text, boundary } = build([file()], '');
    expect(parts(text, boundary)).toHaveLength(2);
  });

  it('wraps attachment base64 at 76 characters and round-trips binary data', () => {
    const data = Buffer.from(Array.from({ length: 5000 }, (_, i) => i % 256));
    const { text, boundary } = build([file({ data })]);
    const body = parts(text, boundary)[1].split('\r\n\r\n')[1];
    for (const line of body.split('\r\n')) {
      expect(line.length).toBeLessThanOrEqual(76);
    }
    expect(
      Buffer.from(body.split('\r\n').join(''), 'base64').equals(data),
    ).toBe(true);
  });

  it('uses a different boundary per message and never one that appears in the content', () => {
    const a = build([file()]);
    const b = build([file()]);
    expect(a.boundary).not.toBe(b.boundary);
    expect(a.boundary.length).toBeGreaterThan(20);
    expect(parts(a.text, a.boundary)).toHaveLength(2);
  });

  it('adds RFC 2231 filename* for a non-ASCII filename, with an ASCII fallback', () => {
    const { text, boundary } = build([file({ filename: 'café (1).pdf' })]);
    const part = parts(text, boundary)[1];
    expect(part).toContain('name="caf_ (1).pdf"');
    expect(part).toContain(
      `filename="caf_ (1).pdf";\r\n filename*=UTF-8''caf%C3%A9%20%281%29.pdf`,
    );
  });

  it('splits a very long encoded filename into folded continuations under 998 characters per line', () => {
    const filename = '文'.repeat(250) + '.pdf';
    const { text, boundary } = build([file({ filename })]);
    const part = parts(text, boundary)[1];
    const headerBlock = part.split('\r\n\r\n')[0];
    for (const line of headerBlock.split('\r\n')) {
      expect(line.length).toBeLessThan(998);
    }
    const encoded = [
      ...headerBlock.matchAll(/filename\*\d+\*=(?:UTF-8'')?([^;\r]+)/g),
    ]
      .map((m) => m[1])
      .join('');
    expect(decodeURIComponent(encoded)).toBe(filename);
  });

  it('strips quotes and backslashes from the quoted filename', () => {
    const { text, boundary } = build([file({ filename: 'a"b\\c.txt' })]);
    const part = parts(text, boundary)[1];
    expect(part).toContain('filename="abc.txt"');
    expect(part).toContain('name="abc.txt"');
  });

  it('cannot be used to inject headers through the filename or content type', () => {
    const { text, boundary } = build([
      file({
        filename: 'x.txt"\r\nBcc: attacker@evil.test\r\nX-Injected: yes',
        contentType: 'text/plain\r\nBcc: attacker@evil.test',
      }),
    ]);
    const part = parts(text, boundary)[1];
    const headerLines = part.split('\r\n\r\n')[0].split('\r\n');
    expect(headerLines).toHaveLength(3);
    expect(headerLines.some((l) => l.startsWith('Bcc:'))).toBe(false);
    expect(headerLines.some((l) => l.startsWith('X-Injected'))).toBe(false);
    expect(headerLines[0]).toMatch(
      /^Content-Type: application\/octet-stream; /,
    );
    expect(text.split('\r\n\r\n')[0]).not.toContain('Bcc: attacker');
  });

  it.each([
    ['image/png', 'image/png'],
    ['application/vnd.ms-excel', 'application/vnd.ms-excel'],
    ['text/plain; charset=utf-8', 'application/octet-stream'],
    ['', 'application/octet-stream'],
    ['notatype', 'application/octet-stream'],
    ['a/b/c', 'application/octet-stream'],
    ['text/html"<x>', 'application/octet-stream'],
  ])('maps content type %j to %j', (input, expected) => {
    expect(sanitizeContentType(input)).toBe(expected);
  });

  it('falls back to a generic filename when nothing is left after sanitizing', () => {
    const { text, boundary } = build([file({ filename: '""' })]);
    expect(parts(text, boundary)[1]).toContain('filename="attachment"');
  });
});
