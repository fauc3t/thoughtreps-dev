// Shared header-construction/sanitization helpers used by both the reply
// Lambda (infra/lambda/reply/buildRawMessage.ts) and the forward Lambda
// (infra/lambda/forward/buildForwardMessage.ts) — anywhere this app builds a
// raw RFC 5322 message that copies a value out of an original, untrusted
// received message into a new outbound header line.

export const CRLF = '\r\n';
export const BASE64_LINE_LENGTH = 76; // RFC 2045 §6.8 line-length limit for base64 content

// Strips CR/LF and other C0 control characters from any value pulled from
// the *original* message before it's used in a header line. This mailbox
// receives real, unauthenticated internet mail — postal-mime's RFC 2047
// decode-words() step on the original's Subject/Message-ID/References can
// produce a decoded string containing a literal embedded CRLF (verified:
// a crafted `=?UTF-8?B?...?=` encoded-word can decode to e.g.
// "Hi\r\nBcc: attacker@evil.test"), and such a string still passes
// isAscii() below (CR/LF are <= 0x7f), so without this it would be written
// straight into a header line and inject arbitrary extra headers — a
// spoofed Bcc:, a second To:, etc. — into an outbound message sent from
// this trusted, DKIM/SPF/DMARC-aligned domain. This is the actual
// injection boundary; RFC 2047 encoding below is a readability nicety for
// legitimate non-ASCII text, not a safety mechanism on its own —
// In-Reply-To/References never go through that encoding path at all, so
// relying on it alone would leave those two headers unprotected. Every
// value read from an original message before building a header line
// (buildRawMessage.ts's reply headers, buildForwardMessage.ts's forwarded
// Subject) is sanitized through this before any further processing.
export function sanitizeHeaderValue(value: string): string {
  // eslint-disable-next-line no-control-regex -- deliberately matching C0 controls + DEL
  return value.replace(/[\x00-\x1f\x7f]/g, ' ');
}

export function isAscii(value: string): boolean {
  for (let i = 0; i < value.length; i++) {
    if (value.charCodeAt(i) > 0x7f) {
      return false;
    }
  }
  return true;
}

// RFC 2047 encoded-word — only applied when needed. A plain-ASCII subject
// passes through unencoded exactly as-is; encoding every subject
// unconditionally would be spec-compliant too, but would make the common
// case unnecessarily harder to read in a raw-message dump.
export function encodeSubjectHeader(subject: string): string {
  if (isAscii(subject)) {
    return subject;
  }
  const base64 = Buffer.from(subject, 'utf-8').toString('base64');
  return `=?UTF-8?B?${base64}?=`;
}

// Wraps a base64 string at BASE64_LINE_LENGTH characters per line, CRLF
// between lines, per RFC 2045 §6.8 — an unbroken single-line base64 body is
// technically decodable by many clients but isn't spec-compliant and some
// mail infrastructure chokes on overlong lines.
export function wrapBase64(base64: string): string {
  const lines: string[] = [];
  for (let i = 0; i < base64.length; i += BASE64_LINE_LENGTH) {
    lines.push(base64.slice(i, i + BASE64_LINE_LENGTH));
  }
  return lines.join(CRLF);
}
