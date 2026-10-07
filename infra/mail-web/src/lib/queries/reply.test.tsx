import type { ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { CognitoUserSession } from 'amazon-cognito-identity-js';
import { SessionContext } from '../session';
import { useReply } from './reply';

const replyToMessage = vi.fn();
const requestAttachmentUpload = vi.fn();
const uploadAttachment = vi.fn();

vi.mock('../api', () => ({
  replyToMessage: (...args: unknown[]) => replyToMessage(...args),
  requestAttachmentUpload: (...args: unknown[]) =>
    requestAttachmentUpload(...args),
  uploadAttachment: (...args: unknown[]) => uploadAttachment(...args),
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

const base = {
  address: 'hello@thoughtreps.com',
  key: 'hello@thoughtreps.com/inbox/abc123',
};

beforeEach(() => {
  replyToMessage.mockReset();
  requestAttachmentUpload.mockReset();
  uploadAttachment.mockReset();
});

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
      result.current.mutate({ ...base, body: 'Thanks!', files: [] });
    });

    // react-query batches its state notifications through a microtask (see
    // notifyManager.js's `schedule`), so isPending isn't necessarily true
    // the instant mutate() returns — waitFor polls until it settles into
    // that state instead of asserting it synchronously.
    await waitFor(() => expect(result.current.isPending).toBe(true));
    expect(result.current.phase).toBe('sending');

    resolve({ messageId: 'ses-msg-1' });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(replyToMessage).toHaveBeenCalledWith(
      expect.objectContaining({ getIdToken: expect.any(Function) }),
      base.address,
      base.key,
      'Thanks!',
      undefined,
    );
    expect(requestAttachmentUpload).not.toHaveBeenCalled();
    expect(result.current.data).toEqual({ messageId: 'ses-msg-1' });
    expect(result.current.phase).toBeNull();
  });

  it('surfaces a rejected mutation as isError with the thrown error', async () => {
    replyToMessage.mockRejectedValue(new Error('address not configured'));

    const { result } = renderHook(() => useReply(), { wrapper });

    act(() => {
      result.current.mutate({ ...base, body: 'Thanks!', files: [] });
    });

    await waitFor(() => expect(result.current.isError).toBe(true));

    expect(result.current.error?.message).toBe('address not configured');
  });

  it('uploads each file (presign, then S3) before replying with the attachment list', async () => {
    const calls: string[] = [];
    requestAttachmentUpload.mockImplementation(
      async (_s: unknown, _a: string, file: File) => {
        calls.push(`presign ${file.name}`);
        return { key: `att/${file.name}`, url: 'https://s3', fields: {} };
      },
    );
    uploadAttachment.mockImplementation(async (_p: unknown, file: File) => {
      calls.push(`upload ${file.name}`);
    });
    replyToMessage.mockImplementation(async () => {
      calls.push('reply');
      return { messageId: 'm1' };
    });

    const a = new File(['a'], 'a.txt', { type: 'text/plain' });
    const b = new File(['b'], 'b.bin');
    const { result } = renderHook(() => useReply(), { wrapper });

    act(() => {
      result.current.mutate({ ...base, body: 'See attached', files: [a, b] });
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(calls).toEqual([
      'presign a.txt',
      'upload a.txt',
      'presign b.bin',
      'upload b.bin',
      'reply',
    ]);
    expect(requestAttachmentUpload).toHaveBeenCalledWith(
      expect.anything(),
      base.address,
      a,
    );
    expect(uploadAttachment).toHaveBeenCalledWith(
      { key: 'att/a.txt', url: 'https://s3', fields: {} },
      a,
    );
    expect(replyToMessage).toHaveBeenCalledWith(
      expect.anything(),
      base.address,
      base.key,
      'See attached',
      [
        { key: 'att/a.txt', filename: 'a.txt', contentType: 'text/plain' },
        {
          key: 'att/b.bin',
          filename: 'b.bin',
          contentType: 'application/octet-stream',
        },
      ],
    );
  });

  it('allows an empty body when there is an attachment', async () => {
    requestAttachmentUpload.mockResolvedValue({
      key: 'att/a.txt',
      url: 'https://s3',
      fields: {},
    });
    uploadAttachment.mockResolvedValue(undefined);
    replyToMessage.mockResolvedValue({ messageId: 'm1' });

    const { result } = renderHook(() => useReply(), { wrapper });

    act(() => {
      result.current.mutate({
        ...base,
        body: '',
        files: [new File(['a'], 'a.txt', { type: 'text/plain' })],
      });
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(replyToMessage).toHaveBeenCalledWith(
      expect.anything(),
      base.address,
      base.key,
      '',
      [{ key: 'att/a.txt', filename: 'a.txt', contentType: 'text/plain' }],
    );
  });

  it('reports the uploading phase while a file is uploading', async () => {
    let finishUpload!: () => void;
    requestAttachmentUpload.mockResolvedValue({
      key: 'att/a.txt',
      url: 'https://s3',
      fields: {},
    });
    uploadAttachment.mockReturnValue(
      new Promise<void>((res) => {
        finishUpload = res;
      }),
    );
    replyToMessage.mockResolvedValue({ messageId: 'm1' });

    const { result } = renderHook(() => useReply(), { wrapper });

    act(() => {
      result.current.mutate({
        ...base,
        body: 'x',
        files: [new File(['a'], 'a.txt')],
      });
    });

    await waitFor(() => expect(result.current.phase).toBe('uploading'));

    finishUpload();

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.phase).toBeNull();
  });

  it('surfaces an S3 upload failure and does not call reply', async () => {
    requestAttachmentUpload.mockResolvedValue({
      key: 'att/a.txt',
      url: 'https://s3',
      fields: {},
    });
    uploadAttachment.mockRejectedValue(new Error("Couldn't upload a.txt"));

    const { result } = renderHook(() => useReply(), { wrapper });

    act(() => {
      result.current.mutate({
        ...base,
        body: 'x',
        files: [new File(['a'], 'a.txt')],
      });
    });

    await waitFor(() => expect(result.current.isError).toBe(true));

    expect(result.current.error?.message).toBe("Couldn't upload a.txt");
    expect(replyToMessage).not.toHaveBeenCalled();
    expect(result.current.phase).toBeNull();
  });
});
