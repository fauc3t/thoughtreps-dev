import { randomBytes } from 'node:crypto';
import {
  CRLF,
  encodeSubjectHeader,
  sanitizeHeaderValue,
} from '../shared/mimeHeaders.js';

// The subset of a parsed original message this function actually needs —
// same "don't depend on postal-mime here" reasoning as
// reply/buildRawMessage.ts's own OriginalMessage type. index.ts only ever
// needs to parse .subject out of the original, so that's the only field
// declared here.
export interface OriginalMessage {
  subject: string | null;
}

function buildForwardSubject(originalSubject: string): string {
  const alreadyPrefixed = /^fwd:\s/i.test(originalSubject);
  return alreadyPrefixed ? originalSubject : `Fwd: ${originalSubject}`;
}

// Forwards the original message losslessly as a message/rfc822 attachment,
// rather than parsing/rebuilding its own headers and body. This is
// deliberate: it avoids re-implementing header-injection defenses
// (sanitizeHeaderValue, etc.) for every field of the original — From, To,
// Date, and so on — since none of the original's raw header *lines* are
// ever copied into a header line of this new outer message. Only the
// Subject *text* is read out of the original, and it's routed through
// sanitizeHeaderValue (imported from the shared mimeHeaders module reply/
// buildRawMessage.ts also uses) before being used to build the outer
// Subject header, for the same reason that module documents: postal-mime's
// RFC 2047 decode step on the original's Subject can produce a decoded
// string containing a literal embedded CRLF, which would otherwise inject
// arbitrary extra headers into this outbound message.
export function buildForwardMessage(
  original: OriginalMessage,
  rawOriginalBytes: Uint8Array,
  fromAddress: string,
  toAddress: string,
): { raw: Uint8Array } {
  const sanitizedSubject = sanitizeHeaderValue(original.subject ?? '');
  const subject = encodeSubjectHeader(buildForwardSubject(sanitizedSubject));

  // Fixed literal prefix + random hex suffix, not a fixed/predictable
  // boundary — a predictable boundary risks collision with content inside
  // the attached original (a boundary-looking line the original's own body
  // happens to contain), which would corrupt the MIME structure of this
  // outer message. randomBytes(16) is plenty of entropy to make that
  // collision practically impossible.
  const boundary = `----=_Forward_${randomBytes(16).toString('hex')}`;

  // No Date or Message-ID header here — same reasoning
  // reply/buildRawMessage.ts documents for its own reply headers: SES's
  // SendRawEmail unconditionally overwrites both with its own values
  // regardless of what's supplied (confirmed against a real deploy), so
  // generating either here would just be dead code.
  const headers: string[] = [
    'MIME-Version: 1.0',
    `From: ${fromAddress}`,
    `To: ${toAddress}`,
    `Subject: ${subject}`,
    `Content-Type: multipart/mixed; boundary="${boundary}"`,
  ];

  const noteText = `Forwarded from ${fromAddress}\r\n\r\nSubject: ${sanitizedSubject}`;

  const preamble = [...headers, ''].join(CRLF);

  const notePart = [
    `--${boundary}`,
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: 8bit',
    '',
    noteText,
    '',
  ].join(CRLF);

  // Original's raw bytes must appear byte-for-byte, unmodified — SES's
  // inbound-SMTP-received mail can legitimately contain 8-bit content, so
  // 8bit is the accurate Content-Transfer-Encoding declaration here, not a
  // 7bit lie. Since the attachment body must be untouched, it's appended as
  // raw bytes rather than joined as a string through the rest of the
  // message (which would risk a lossy UTF-8 round-trip of bytes that may
  // not even be valid UTF-8).
  const attachmentHeader = [
    `--${boundary}`,
    'Content-Type: message/rfc822',
    'Content-Transfer-Encoding: 8bit',
    '',
    '',
  ].join(CRLF);

  const closingBoundary = `${CRLF}--${boundary}--${CRLF}`;

  const raw = Buffer.concat([
    Buffer.from(preamble + CRLF + notePart, 'utf-8'),
    Buffer.from(attachmentHeader, 'utf-8'),
    Buffer.from(rawOriginalBytes),
    Buffer.from(closingBoundary, 'utf-8'),
  ]);

  return { raw };
}
