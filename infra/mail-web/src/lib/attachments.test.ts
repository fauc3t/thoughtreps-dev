import { describe, expect, it } from 'vitest';
import type { Attachment } from 'postal-mime';
import {
  attachmentByteLength,
  attachmentToBlob,
  downloadableAttachments,
  formatAttachmentSize,
} from './attachments';

function makeAttachment(overrides: Partial<Attachment> = {}): Attachment {
  return {
    filename: 'test.txt',
    mimeType: 'text/plain',
    disposition: 'attachment',
    content: new TextEncoder().encode('hello world').buffer,
    ...overrides,
  };
}

describe('attachmentToBlob', () => {
  it('always uses application/octet-stream, never the parsed (attacker-controlled) mimeType, so a direct blob: URL navigation is never treated as an active document', () => {
    const attachment = makeAttachment({ mimeType: 'text/html' });

    const blob = attachmentToBlob(attachment);

    expect(blob.type).toBe('application/octet-stream');
    expect(blob.size).toBe(11);
  });

  it('decodes base64 string content into real bytes rather than treating it as literal text', () => {
    const attachment = makeAttachment({
      content: btoa('hello world'),
      encoding: 'base64',
    });

    // Decoded byte size (11), not the longer base64-encoded string length
    // (16, including padding) — proof the base64 branch actually decodes
    // rather than passing the encoded text straight through.
    expect(attachmentToBlob(attachment).size).toBe(11);
  });

  it('wraps a plain utf8 string as-is', () => {
    const attachment = makeAttachment({
      content: 'hello world',
      encoding: 'utf8',
    });

    expect(attachmentToBlob(attachment).size).toBe(11);
  });
});

describe('attachmentByteLength', () => {
  it('reads byteLength directly off ArrayBuffer content', () => {
    expect(attachmentByteLength(makeAttachment())).toBe(11);
  });

  it('estimates base64 string content from its encoded length, not the raw string length', () => {
    const attachment = makeAttachment({
      content: btoa('hello world'),
      encoding: 'base64',
    });

    expect(attachmentByteLength(attachment)).toBe(11);
  });
});

describe('formatAttachmentSize', () => {
  it.each([
    [42, '42 B'],
    [2048, '2.0 KB'],
    [5 * 1024 * 1024, '5.0 MB'],
  ])('formats %d bytes as %s', (bytes, expected) => {
    expect(formatAttachmentSize(bytes)).toBe(expected);
  });
});

describe('downloadableAttachments', () => {
  it('excludes attachments marked related (inline cid-referenced images)', () => {
    const inlineImage = makeAttachment({
      filename: 'logo.png',
      related: true,
      contentId: 'logo123',
    });
    const realAttachment = makeAttachment({ filename: 'invoice.pdf' });

    const result = downloadableAttachments([inlineImage, realAttachment]);

    expect(result).toEqual([realAttachment]);
  });
});
