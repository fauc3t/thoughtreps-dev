import type { Attachment } from 'postal-mime';

// postal-mime's default attachmentEncoding is 'arraybuffer' (message.ts calls
// PostalMime.parse with no options), so `content` is normally an
// ArrayBuffer/Uint8Array here — the string branches only matter if that
// default is ever overridden.
//
// The Blob's type is always 'application/octet-stream', never the parsed
// mimeType — mimeType comes straight off an untrusted email's own headers,
// and a browser can navigate directly to a same-origin blob: URL (e.g. via
// "open in new tab", which bypasses the <a download> attribute) rather than
// only ever downloading it. If mimeType were used here, an attacker could
// send a `text/html`/`image/svg+xml` attachment named to look innocuous and
// get it rendered as an active same-origin document instead of downloaded —
// exactly the risk pages/Message.tsx's sandboxed iframe already exists to
// avoid for the message body itself. mimeType is still shown as informational
// text next to the link (AttachmentList.tsx) — only the Blob's own type,
// which actually governs browser handling, is forced inert.
const DOWNLOAD_BLOB_TYPE = 'application/octet-stream';

export function attachmentToBlob(attachment: Attachment): Blob {
  const { content, encoding } = attachment;

  if (typeof content === 'string') {
    if (encoding === 'base64') {
      const binary = atob(content);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i += 1) {
        bytes[i] = binary.charCodeAt(i);
      }
      return new Blob([bytes], { type: DOWNLOAD_BLOB_TYPE });
    }
    return new Blob([content], { type: DOWNLOAD_BLOB_TYPE });
  }

  return new Blob([content], { type: DOWNLOAD_BLOB_TYPE });
}

export function attachmentByteLength(attachment: Attachment): number {
  const { content, encoding } = attachment;

  if (typeof content === 'string') {
    // atob (not a length formula) so padding is accounted for exactly —
    // base64 pads to a multiple of 4 chars, so a flat *3/4 estimate
    // over-counts whenever the unpadded content isn't itself a multiple of 3.
    return encoding === 'base64' ? atob(content).length : content.length;
  }

  return content.byteLength;
}

export function formatAttachmentSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

// Inline images referenced by a `cid:` src inside the HTML body carry
// `related: true` — they're already part of the rendered message, not a
// separate file the user needs to download. (Note: postal-mime marks these
// but doesn't rewrite the `cid:` src itself, so an inline image today
// renders as broken inside the sandboxed iframe regardless — a separate,
// not-yet-fixed gap from the plain download list this filters for.)
export function downloadableAttachments(
  attachments: Attachment[],
): Attachment[] {
  return attachments.filter((attachment) => !attachment.related);
}
