import type { ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';
import { SessionContext } from '../session';
import { useReply } from './reply';

const replyToMessage = vi.fn();

vi.mock('../api', () => ({
  replyToMessage: (...args: unknown[]) => replyToMessage(...args),
}));

function fakeSession(): CognitoUserSession {
  return {
    getIdToken: () => ({ getJwtToken: () => 'test-id-token' }),
  } as unknown as CognitoUserSession;
}

function wrapper({ children }: { children: ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: { mutations: { retry: false } },
  });
  return (
    <QueryClientProvider client={queryClient}>
      <SessionContext.Provider value={fakeSession()}>
        {children}
      </SessionContext.Provider>
    </QueryClientProvider>
  );
}

describe('useReply', () => {
  it('calls replyToMessage with the session and the given variables', async () => {
    // A deferred promise (rather than mockResolvedValue) so isPending can be
    // observed before the mutation settles — mockResolvedValue's promise
    // resolves on the same microtask turn act() already flushes, which
    // would make the mutation look already-settled by the time isPending is
    // checked below.
    let resolve!: (value: { messageId: string }) => void;
    replyToMessage.mockReturnValue(
      new Promise((res) => {
        resolve = res;
      }),
    );

    const { result } = renderHook(() => useReply(), { wrapper });

    act(() => {
      result.current.mutate({
        address: 'hello@thoughtreps.com',
        key: 'hello@thoughtreps.com/inbox/abc123',
        body: 'Thanks!',
      });
    });

    // react-query batches its state notifications through a microtask (see
    // notifyManager.js's `schedule`), so isPending isn't necessarily true
    // the instant mutate() returns — waitFor polls until it settles into
    // that state instead of asserting it synchronously.
    await waitFor(() => expect(result.current.isPending).toBe(true));

    resolve({ messageId: 'ses-msg-1' });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(replyToMessage).toHaveBeenCalledWith(
      expect.objectContaining({ getIdToken: expect.any(Function) }),
      'hello@thoughtreps.com',
      'hello@thoughtreps.com/inbox/abc123',
      'Thanks!',
    );
    expect(result.current.data).toEqual({ messageId: 'ses-msg-1' });
  });

  it('surfaces a rejected mutation as isError with the thrown error', async () => {
    replyToMessage.mockRejectedValue(new Error('address not configured'));

    const { result } = renderHook(() => useReply(), { wrapper });

    act(() => {
      result.current.mutate({
        address: 'hello@thoughtreps.com',
        key: 'hello@thoughtreps.com/inbox/abc123',
        body: 'Thanks!',
      });
    });

    await waitFor(() => expect(result.current.isError).toBe(true));

    expect(result.current.error?.message).toBe('address not configured');
  });
});
