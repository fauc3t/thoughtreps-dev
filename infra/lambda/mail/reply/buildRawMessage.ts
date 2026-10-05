import {
  CRLF,
  encodeSubjectHeader,
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

  headers.push(
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=UTF-8',
    // Declared unconditionally, not just when replyBody turns out to
    // contain non-ASCII — the body's content isn't known to be ASCII-safe
    // ahead of time, and getting this wrong doesn't fail on a plain-ASCII
    // test reply, it silently corrupts the first real reply that contains
    // an accented character, emoji, or curly quote.
    'Content-Transfer-Encoding: base64',
  );

  const encodedBody = wrapBase64(
    Buffer.from(replyBody, 'utf-8').toString('base64'),
  );

  const message = [...headers, '', encodedBody].join(CRLF);

  return { to, raw: Buffer.from(message, 'utf-8') };
}
