import { afterEach, describe, expect, it, vi } from 'vitest';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';

vi.mock('./config', () => ({
  API_URL: 'https://api.example.com',
}));

function fakeSession(): CognitoUserSession {
  return {
    getIdToken: () => ({ getJwtToken: () => 'test-id-token' }),
  } as unknown as CognitoUserSession;
}

function jsonResponse(status: number, body: unknown): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body,
  } as Response;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('requestAttachmentUpload', () => {
  it('POSTs the file metadata to {API_URL}/attachments with a Bearer ID token', async () => {
    const post = {
      key: 'k1',
      url: 'https://s3.example.com',
      fields: { a: 'b' },
    };
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(200, post));
    vi.stubGlobal('fetch', fetchMock);

    const { requestAttachmentUpload } = await import('./api');
    const file = new File(['hello'], 'a.txt', { type: 'text/plain' });

    expect(
      await requestAttachmentUpload(fakeSession(), 'a@b.com', file),
    ).toEqual(post);
    const [url, options] = fetchMock.mock.calls[0];
    expect(url).toBe('https://api.example.com/attachments');
    expect(options.headers.Authorization).toBe('Bearer test-id-token');
    expect(JSON.parse(options.body)).toEqual({
      address: 'a@b.com',
      filename: 'a.txt',
      contentType: 'text/plain',
      size: 5,
    });
  });

  it('throws the server error message on a non-2xx response', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(jsonResponse(400, { error: 'bad file' })),
    );
    const { requestAttachmentUpload } = await import('./api');

    await expect(
      requestAttachmentUpload(fakeSession(), 'a@b.com', new File(['x'], 'a')),
    ).rejects.toThrow('bad file');
  });
});

describe('uploadAttachment', () => {
  const post = {
    key: 'k1',
    url: 'https://s3.example.com',
    fields: { policy: 'p', signature: 's' },
  };

  it('POSTs fields, then Content-Type, then file last, with no Authorization header', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ status: 204 } as Response);
    vi.stubGlobal('fetch', fetchMock);
    const { uploadAttachment } = await import('./api');
    const file = new File(['hello'], 'a.txt', { type: 'text/plain' });

    await uploadAttachment(post, file);

    const [url, options] = fetchMock.mock.calls[0];
    expect(url).toBe('https://s3.example.com');
    expect(options.method).toBe('POST');
    expect(options.headers).toBeUndefined();
    const form = options.body as FormData;
    expect(Array.from(form.keys())).toEqual([
      'policy',
      'signature',
      'Content-Type',
      'file',
    ]);
    expect(form.get('Content-Type')).toBe('text/plain');
  });

  it('falls back to application/octet-stream when the file has no type', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ status: 204 } as Response);
    vi.stubGlobal('fetch', fetchMock);
    const { uploadAttachment } = await import('./api');

    await uploadAttachment(post, new File(['x'], 'a'));

    const form = fetchMock.mock.calls[0][1].body as FormData;
    expect(form.get('Content-Type')).toBe('application/octet-stream');
  });

  it("throws \"Couldn't upload <filename>\" on a non-204 response", async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({ status: 403 } as Response),
    );
    const { uploadAttachment } = await import('./api');

    await expect(
      uploadAttachment(post, new File(['x'], 'a.txt')),
    ).rejects.toThrow("Couldn't upload a.txt");
  });
});

describe('replyToMessage attachments', () => {
  it('includes the attachment list in the request body', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(jsonResponse(200, { messageId: 'm' }));
    vi.stubGlobal('fetch', fetchMock);
    const { replyToMessage } = await import('./api');
    const attachments = [
      { key: 'k1', filename: 'a.txt', contentType: 'text/plain' },
    ];

    await replyToMessage(fakeSession(), 'a@b.com', 'a@b.com/inbox/x', '', attachments);

    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
      address: 'a@b.com',
      key: 'a@b.com/inbox/x',
      body: '',
      attachments,
    });
  });
});
