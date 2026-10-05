import type { ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';
import { SessionContext } from '../session';
import { useDeleteMessage } from './delete';

const deleteMessage = vi.fn();

vi.mock('../api', () => ({
  deleteMessage: (...args: unknown[]) => deleteMessage(...args),
}));

function fakeSession(): CognitoUserSession {
  return {
    getIdToken: () => ({ getJwtToken: () => 'test-id-token' }),
  } as unknown as CognitoUserSession;
}

function makeWrapper(queryClient: QueryClient) {
  return function wrapper({ children }: { children: ReactNode }) {
    return (
      <QueryClientProvider client={queryClient}>
        <SessionContext.Provider value={fakeSession()}>
          {children}
        </SessionContext.Provider>
      </QueryClientProvider>
    );
  };
}

describe('useDeleteMessage', () => {
  it('calls deleteMessage with the session, hook-scoped address, and the given key', async () => {
    // A deferred promise (rather than mockResolvedValue) so isPending can be
    // observed before the mutation settles — mirrors reply.test.tsx's own
    // reasoning for the same pattern.
    let resolve!: (value: { success: true }) => void;
    deleteMessage.mockReturnValue(
      new Promise((res) => {
        resolve = res;
      }),
    );

    const queryClient = new QueryClient({
      defaultOptions: { mutations: { retry: false } },
    });
    const { result } = renderHook(
      () => useDeleteMessage('hello@thoughtreps.com'),
      {
        wrapper: makeWrapper(queryClient),
      },
    );

    act(() => {
      result.current.mutate('hello@thoughtreps.com/inbox/abc123');
    });

    await waitFor(() => expect(result.current.isPending).toBe(true));

    resolve({ success: true });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(deleteMessage).toHaveBeenCalledWith(
      expect.objectContaining({ getIdToken: expect.any(Function) }),
      'hello@thoughtreps.com',
      'hello@thoughtreps.com/inbox/abc123',
    );
  });

  it('surfaces a rejected mutation as isError with the thrown error', async () => {
    deleteMessage.mockRejectedValue(new Error('key mismatch'));

    const queryClient = new QueryClient({
      defaultOptions: { mutations: { retry: false } },
    });
    const { result } = renderHook(
      () => useDeleteMessage('hello@thoughtreps.com'),
      {
        wrapper: makeWrapper(queryClient),
      },
    );

    act(() => {
      result.current.mutate('hello@thoughtreps.com/inbox/abc123');
    });

    await waitFor(() => expect(result.current.isError).toBe(true));

    expect(result.current.error?.message).toBe('key mismatch');
  });

  it("invalidates the ['messages', address] query on a successful delete", async () => {
    deleteMessage.mockResolvedValue({ success: true });

    const queryClient = new QueryClient({
      defaultOptions: { mutations: { retry: false } },
    });
    const invalidateSpy = vi.spyOn(queryClient, 'invalidateQueries');

    const { result } = renderHook(
      () => useDeleteMessage('hello@thoughtreps.com'),
      {
        wrapper: makeWrapper(queryClient),
      },
    );

    act(() => {
      result.current.mutate('hello@thoughtreps.com/inbox/abc123');
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(invalidateSpy).toHaveBeenCalledWith({
      queryKey: ['messages', 'hello@thoughtreps.com'],
    });
  });
});
