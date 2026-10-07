import { randomBytes } from 'node:crypto';
import {
  CRLF,
  encodeSubjectHeader,
  isAscii,
  sanitizeHeaderValue,
  wrapBase64,
} from '../shared/mimeHeaders.js';

// The subset of a parsed original message this function actually needs —
// deliberately not postal-mime's own `Email` type, so this file (and its
// test) never has to depend on postal-mime at all. index.ts is responsible
// for narrowing whatever postal-mime hands back down to this shape.
export interface OriginalMessage {
  messageId: string | null;
  references: string | null; // postal-mime's raw References header value, if present
  subject: string | null;
  from: { address: string | null; name?: string | null } | null;
}

export interface OutgoingAttachment {
  filename: string;
  contentType: string;
  data: Uint8Array;
}

const CONTENT_TYPE_TOKEN =
  /^[A-Za-z0-9!#$&^_.+-]{1,127}\/[A-Za-z0-9!#$&^_.+-]{1,127}$/;

// Comes from the browser, so it's untrusted header input: the token regex
// (no parameters, no whitespace) rejects anything that could extend the
// header, and sanitizeHeaderValue runs first as the injection boundary.
export function sanitizeContentType(contentType: string): string {
  const cleaned = sanitizeHeaderValue(contentType).trim();
  return CONTENT_TYPE_TOKEN.test(cleaned)
    ? cleaned
    : 'application/octet-stream';
}

function sanitizeFilename(filename: string): string {
  const cleaned = sanitizeHeaderValue(filename).replace(/["\\]/g, '').trim();
  return cleaned || 'attachment';
}

// RFC 5987 attr-char: encodeURIComponent also leaves !'()* unescaped.
function percentEncode(codePoint: string): string {
  return encodeURIComponent(codePoint).replace(
    /[!'()*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

// An encoded filename can exceed the 998-char line limit (3 bytes -> 9
// chars), so it is split into RFC 2231 continuations on code point
// boundaries, folded onto separate lines.
function encodeExtendedFilename(filename: string): string {
  const segments: string[] = [];
  let current = '';
  for (const codePoint of filename) {
    const encoded = percentEncode(codePoint);
    if (current.length + encoded.length > 600) {
      segments.push(current);
      current = '';
    }
    current += encoded;
  }
  segments.push(current);
  if (segments.length === 1) {
    return `filename*=UTF-8''${segments[0]}`;
  }
  return segments
    .map((segment, i) =>
      i === 0 ? `filename*0*=UTF-8''${segment}` : `filename*${i}*=${segment}`,
    )
    .join(`;${CRLF} `);
}

function buildAttachmentPart(attachment: OutgoingAttachment): Buffer {
  const filename = sanitizeFilename(attachment.filename);
  const contentType = sanitizeContentType(attachment.contentType);
  // Plain-ASCII fallback for clients that ignore filename*; the control
  // characters are already gone, so this only touches non-ASCII.
  const asciiName = filename.replace(/[^ -~]/gu, '_');
  const disposition = [`attachment; filename="${asciiName}"`];
  if (!isAscii(filename)) {
    disposition.push(encodeExtendedFilename(filename));
  }
  const head = [
    `Content-Type: ${contentType}; name="${asciiName}"`,
    `Content-Disposition: ${disposition.join(`;${CRLF} `)}`,
    'Content-Transfer-Encoding: base64',
    '',
    '',
  ].join(CRLF);
  return Buffer.concat([
    Buffer.from(head, 'utf-8'),
    Buffer.from(
      wrapBase64(Buffer.from(attachment.data).toString('base64')),
      'ascii',
    ),
  ]);
}

function buildSubject(originalSubject: string | null): string {
  const subject = originalSubject ?? '';
  const alreadyPrefixed = /^re:\s/i.test(subject);
  return alreadyPrefixed ? subject : `Re: ${subject}`;
}

// Append, don't replace, per RFC 5322 §3.6.4 threading semantics — a reply's
// References header is the whole ancestor chain, not just the message it's
// directly replying to.
function buildReferences(
  originalReferences: string | null,
  originalMessageId: string | null,
): string | null {
  if (!originalMessageId) {
    return originalReferences;
  }
  return originalReferences
    ? `${originalReferences} ${originalMessageId}`
    : originalMessageId;
}

export function buildRawMessage(
  original: OriginalMessage,
  replyBody: string,
  fromAddress: string,
  attachments: OutgoingAttachment[] = [],
): { to: string; raw: Uint8Array } {
  const to = original.from?.address
    ? sanitizeHeaderValue(original.from.address)
    : null;
  if (!to) {
    throw new Error(
      'Cannot build a reply: original message has no From address to reply to',
    );
  }

  const originalSubject = original.subject
    ? sanitizeHeaderValue(original.subject)
    : null;
  const originalMessageId = original.messageId
    ? sanitizeHeaderValue(original.messageId)
    : null;
  const originalReferences = original.references
    ? sanitizeHeaderValue(original.references)
    : null;

  const subject = encodeSubjectHeader(buildSubject(originalSubject));
  const references = buildReferences(originalReferences, originalMessageId);

  // No Date or Message-ID header here, deliberately — SES's SendRawEmail
  // unconditionally overwrites both with its own values regardless of what
  // a raw message supplies (confirmed in AWS's own API reference: "Amazon
  // SES automatically applies its own Message-ID and Date headers; if you
  // passed these headers when creating the message, they are overwritten
  // by the values that Amazon SES provides" — and confirmed the hard way
  // against a real deployed send, where a previous version of this
  // function's own generated Message-ID never reached the delivered mail
  // at all). Generating either here was dead code pretending to control
  // something this function has no way to control; index.ts's own
  // Source-address-based threading (In-Reply-To/References) is unaffected
  // either way, since those reference the *original* message, not this
  // reply's own identity.
  const headers: string[] = [
    `To: ${to}`,
    `From: ${fromAddress}`,
    `Subject: ${subject}`,
  ];

  if (originalMessageId) {
    headers.push(`In-Reply-To: ${originalMessageId}`);
  }
  if (references) {
    headers.push(`References: ${references}`);
  }

  const boundary = `=_${randomBytes(18).toString('hex')}`;
  const multipart = attachments.length > 0;

  headers.push(
    'MIME-Version: 1.0',
    multipart
      ? `Content-Type: multipart/mixed; boundary="${boundary}"`
      : 'Content-Type: text/plain; charset=UTF-8',
  );
  if (!multipart) {
    // Declared unconditionally, not just when replyBody turns out to
    // contain non-ASCII — the body's content isn't known to be ASCII-safe
    // ahead of time, and getting this wrong doesn't fail on a plain-ASCII
    // test reply, it silently corrupts the first real reply that contains
    // an accented character, emoji, or curly quote. (In the multipart case
    // the text part declares it itself.)
    headers.push('Content-Transfer-Encoding: base64');
  }

  const encodedBody = wrapBase64(
    Buffer.from(replyBody, 'utf-8').toString('base64'),
  );

  if (!multipart) {
    const message = [...headers, '', encodedBody].join(CRLF);
    return { to, raw: Buffer.from(message, 'utf-8') };
  }

  // The boundary can't occur in any part body: bodies are base64, whose
  // alphabet has no '_'. Header values are single-line (sanitized), so they
  // can't start a line with the delimiter either.
  const textPart = [
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    encodedBody,
  ].join(CRLF);
  const delimiter = Buffer.from(`${CRLF}--${boundary}${CRLF}`, 'ascii');
  const parts: Buffer[] = [
    Buffer.from(`${headers.join(CRLF)}${CRLF}${CRLF}`, 'utf-8'),
    Buffer.from(`--${boundary}${CRLF}${textPart}`, 'utf-8'),
  ];
  for (const attachment of attachments) {
    parts.push(delimiter, buildAttachmentPart(attachment));
  }
  parts.push(Buffer.from(`${CRLF}--${boundary}--${CRLF}`, 'ascii'));

  return { to, raw: Buffer.concat(parts) };
}
