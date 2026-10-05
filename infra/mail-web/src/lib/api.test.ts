import { afterEach, describe, expect, it, vi } from 'vitest';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';

vi.mock('./config', () => ({
  API_URL: 'https://api.example.com',
}));

function fakeSession(): CognitoUserSession {
  return {
    getIdToken: () => ({ getJwtToken: () => 'test-id-token' }),
    getAccessToken: () => ({ getJwtToken: () => 'test-access-token' }),
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

describe('replyToMessage', () => {
  it('POSTs to {API_URL}/reply with a Bearer ID token and the exact request body', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(jsonResponse(200, { messageId: 'ses-msg-1' }));
    vi.stubGlobal('fetch', fetchMock);

    const { replyToMessage } = await import('./api');

    const result = await replyToMessage(
      fakeSession(),
      'hello@thoughtreps.com',
      'hello@thoughtreps.com/inbox/abc123',
      'Thanks for reaching out.',
    );

    expect(result).toEqual({ messageId: 'ses-msg-1' });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, options] = fetchMock.mock.calls[0];
    expect(url).toBe('https://api.example.com/reply');
    expect(options.method).toBe('POST');
    expect(options.headers).toEqual({
      Authorization: 'Bearer test-id-token',
      'Content-Type': 'application/json',
    });
    expect(JSON.parse(options.body)).toEqual({
      address: 'hello@thoughtreps.com',
      key: 'hello@thoughtreps.com/inbox/abc123',
      body: 'Thanks for reaching out.',
    });
  });

  it('never sends the access token as the Bearer credential', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(jsonResponse(200, { messageId: 'ses-msg-1' }));
    vi.stubGlobal('fetch', fetchMock);

    const { replyToMessage } = await import('./api');

    await replyToMessage(fakeSession(), 'a@b.com', 'a@b.com/inbox/x', 'hi');

    const [, options] = fetchMock.mock.calls[0];
    expect(options.headers.Authorization).not.toContain('test-access-token');
  });

  it("throws an Error with the response body's message on a non-2xx response", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(
        jsonResponse(400, { error: 'address not configured' }),
      );
    vi.stubGlobal('fetch', fetchMock);

    const { replyToMessage } = await import('./api');

    await expect(
      replyToMessage(fakeSession(), 'a@b.com', 'a@b.com/inbox/x', 'hi'),
    ).rejects.toThrow('address not configured');
  });

  it('falls back to a generic status-coded message when the error response is not valid JSON', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: false,
      status: 502,
      json: async () => {
        throw new SyntaxError('Unexpected end of JSON input');
      },
    } as unknown as Response);
    vi.stubGlobal('fetch', fetchMock);

    const { replyToMessage } = await import('./api');

    await expect(
      replyToMessage(fakeSession(), 'a@b.com', 'a@b.com/inbox/x', 'hi'),
    ).rejects.toThrow('Request failed (502)');
  });
});

describe('deleteMessage', () => {
  it('POSTs to {API_URL}/delete with a Bearer ID token and the exact request body', async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(jsonResponse(200, { success: true }));
    vi.stubGlobal('fetch', fetchMock);

    const { deleteMessage } = await import('./api');

    const result = await deleteMessage(
      fakeSession(),
      'hello@thoughtreps.com',
      'hello@thoughtreps.com/inbox/abc123',
    );

    expect(result).toEqual({ success: true });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, options] = fetchMock.mock.calls[0];
    expect(url).toBe('https://api.example.com/delete');
    expect(options.method).toBe('POST');
    expect(options.headers).toEqual({
      Authorization: 'Bearer test-id-token',
      'Content-Type': 'application/json',
    });
    expect(JSON.parse(options.body)).toEqual({
      address: 'hello@thoughtreps.com',
      key: 'hello@thoughtreps.com/inbox/abc123',
    });
  });

  it("throws an Error with the response body's message on a non-2xx response", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(jsonResponse(400, { error: 'key mismatch' }));
    vi.stubGlobal('fetch', fetchMock);

    const { deleteMessage } = await import('./api');

    await expect(
      deleteMessage(fakeSession(), 'a@b.com', 'a@b.com/inbox/x'),
    ).rejects.toThrow('key mismatch');
  });

  it('falls back to a generic status-coded message when the error response is not valid JSON', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: false,
      status: 502,
      json: async () => {
        throw new SyntaxError('Unexpected end of JSON input');
      },
    } as unknown as Response);
    vi.stubGlobal('fetch', fetchMock);

    const { deleteMessage } = await import('./api');

    await expect(
      deleteMessage(fakeSession(), 'a@b.com', 'a@b.com/inbox/x'),
    ).rejects.toThrow('Request failed (502)');
  });
});
