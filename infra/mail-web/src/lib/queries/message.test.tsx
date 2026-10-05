import type { ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';
import { SessionContext } from '../session';
import { useMessage } from './message';

const send = vi.fn();

vi.mock('../s3Client', () => ({
  getS3Client: () => ({ send }),
}));

// A small, realistic RFC822 multipart/alternative message — headers plus a
// text/plain and text/html part. Deliberately not mocking postal-mime
// itself: it's pure/deterministic, so parsing this for real catches
// integration bugs a mocked parser would hide.
const RAW_EMAIL = [
  'From: Alice Sender <alice@example.com>',
  'To: bob@example.com',
  'Subject: Test Subject',
  'Date: Wed, 01 Jan 2026 12:00:00 +0000',
  'MIME-Version: 1.0',
  'Content-Type: multipart/alternative; boundary="BOUNDARY"',
  '',
  '--BOUNDARY',
  'Content-Type: text/plain; charset="utf-8"',
  '',
  'Hello Bob, this is plain text.',
  '',
  '--BOUNDARY',
  'Content-Type: text/html; charset="utf-8"',
  '',
  '<p>Hello Bob, this is <strong>HTML</strong>.</p>',
  '',
  '--BOUNDARY--',
  '',
].join('\r\n');

function fakeSession(): CognitoUserSession {
  return {
    getIdToken: () => ({ getJwtToken: () => 'test-id-token' }),
  } as unknown as CognitoUserSession;
}

function wrapper({ children }: { children: ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return (
    <QueryClientProvider client={queryClient}>
      <SessionContext.Provider value={fakeSession()}>
        {children}
      </SessionContext.Provider>
    </QueryClientProvider>
  );
}

describe('useMessage', () => {
  it('parses a raw MIME object body into subject/from/html', async () => {
    send.mockResolvedValue({
      Body: {
        transformToByteArray: async () => new TextEncoder().encode(RAW_EMAIL),
      },
    });

    const { result } = renderHook(
      () => useMessage('alice@example.com/inbox/test.eml'),
      { wrapper },
    );

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(result.current.data?.subject).toBe('Test Subject');
    expect(result.current.data?.from).toEqual({
      name: 'Alice Sender',
      address: 'alice@example.com',
    });
    expect(result.current.data?.html).toContain('<strong>HTML</strong>');
    expect(result.current.data?.text?.trim()).toBe(
      'Hello Bob, this is plain text.',
    );
  });

  it('rejects when the object has no body', async () => {
    send.mockResolvedValue({ Body: undefined });

    const { result } = renderHook(
      () => useMessage('missing@example.com/inbox/missing.eml'),
      { wrapper },
    );

    await waitFor(() => expect(result.current.isError).toBe(true));
  });
});
