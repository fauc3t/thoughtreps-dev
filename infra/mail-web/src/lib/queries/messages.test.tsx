import type { ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';
import { SessionContext } from '../session';
import { useMessages } from './messages';

const send = vi.fn();

vi.mock('../s3Client', () => ({
  getS3Client: () => ({ send }),
}));

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

describe('useMessages', () => {
  it('sorts messages newest-first by LastModified', async () => {
    send.mockResolvedValue({
      Contents: [
        {
          Key: 'a@example.com/inbox/oldest.eml',
          LastModified: new Date('2026-01-01T00:00:00Z'),
        },
        {
          Key: 'a@example.com/inbox/newest.eml',
          LastModified: new Date('2026-03-01T00:00:00Z'),
        },
        {
          Key: 'a@example.com/inbox/middle.eml',
          LastModified: new Date('2026-02-01T00:00:00Z'),
        },
      ],
    });

    const { result } = renderHook(() => useMessages('a@example.com'), {
      wrapper,
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(result.current.data?.map((o) => o.Key)).toEqual([
      'a@example.com/inbox/newest.eml',
      'a@example.com/inbox/middle.eml',
      'a@example.com/inbox/oldest.eml',
    ]);
  });

  it('returns an empty list when the prefix has no objects', async () => {
    send.mockResolvedValue({ Contents: undefined });

    const { result } = renderHook(() => useMessages('empty@example.com'), {
      wrapper,
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data).toEqual([]);
  });
});
