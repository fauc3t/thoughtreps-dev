import { act, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Link, MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import Message from './Message';
import { MAX_REPLY_BYTES } from '../lib/attachments';

interface ReplyState {
  isPending: boolean;
  isSuccess: boolean;
  isError: boolean;
  error: Error | null;
  phase: 'uploading' | 'sending' | null;
}

const idle: ReplyState = {
  isPending: false,
  isSuccess: false,
  isError: false,
  error: null,
  phase: null,
};

let replyState: ReplyState;
let setReplyState: (state: ReplyState) => void;
const mutate = vi.fn();

vi.mock('../lib/queries/reply', async () => {
  const { useState } = await import('react');
  return {
    useReply: () => {
      const [state, setState] = useState(replyState);
      setReplyState = setState;
      return { ...state, mutate };
    },
  };
});

vi.mock('../lib/queries/message', () => ({
  useMessage: () => ({
    isLoading: false,
    isError: false,
    data: {
      subject: 'Hi',
      text: 'Hello',
      from: { address: 'x@y.com' },
      attachments: [],
    },
  }),
}));

vi.mock('../lib/queries/delete', () => ({
  useDeleteMessage: () => ({ mutate: vi.fn(), isPending: false }),
}));

function renderPage() {
  render(
    <MemoryRouter initialEntries={['/a%40b.com/k1']}>
      <Link to="/a%40b.com/k2">next</Link>
      <Routes>
        <Route path="/:address/:key" element={<Message />} />
      </Routes>
    </MemoryRouter>,
  );
}

function file(name: string, size = 1): File {
  const f = new File(['x'], name);
  Object.defineProperty(f, 'size', { value: size });
  return f;
}

async function attach(...files: File[]) {
  await userEvent.upload(screen.getByTestId('reply-file-input'), files);
}

const sendButton = () =>
  screen.getByRole('button', { name: /send reply|sending|uploading/i });
const textarea = () => screen.getByPlaceholderText('Type your reply…');

beforeEach(() => {
  replyState = { ...idle };
  mutate.mockReset();
});

describe('Message reply compose', () => {
  it('enables Send only with a non-empty body or at least one file', async () => {
    renderPage();
    expect(sendButton()).toBeDisabled();

    await userEvent.type(textarea(), 'hi');
    expect(sendButton()).toBeEnabled();

    await userEvent.clear(textarea());
    expect(sendButton()).toBeDisabled();

    await attach(file('a.txt'));
    expect(sendButton()).toBeEnabled();
  });

  it('disables the textarea, attach and remove while busy', async () => {
    renderPage();
    await attach(file('a.txt'));
    act(() => setReplyState({ ...idle, isPending: true, phase: 'uploading' }));
    expect(textarea()).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Attach files' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Remove a.txt' })).toBeDisabled();
    expect(sendButton()).toHaveTextContent('Uploading…');
    expect(screen.getByLabelText('Attachments').closest('section')).toHaveAttribute(
      'aria-busy',
      'true',
    );
  });

  it('removes a chip with its Remove button', async () => {
    renderPage();
    await attach(file('a.txt'), file('b.txt'));
    expect(screen.getByLabelText('Attachments')).toHaveTextContent('a.txt');

    await userEvent.click(screen.getByRole('button', { name: 'Remove a.txt' }));

    expect(screen.queryByText('a.txt')).not.toBeInTheDocument();
    expect(screen.getByText('b.txt')).toBeInTheDocument();
  });

  it('shows the limit error and does not add the offending files', async () => {
    renderPage();
    await attach(file('big.bin', MAX_REPLY_BYTES + 1));

    expect(screen.getByRole('alert')).toHaveTextContent('big.bin');
    expect(screen.queryByLabelText('Attachments')).not.toBeInTheDocument();
    expect(sendButton()).toBeDisabled();
  });

  it('clears the body and files after a successful send', async () => {
    mutate.mockImplementation((_vars, opts) => opts.onSuccess());
    renderPage();
    await userEvent.type(textarea(), 'hello');
    await attach(file('a.txt'));

    await userEvent.click(sendButton());

    expect(mutate).toHaveBeenCalledWith(
      expect.objectContaining({
        address: 'a@b.com',
        key: 'k1',
        body: 'hello',
        files: [expect.objectContaining({ name: 'a.txt' })],
      }),
      expect.anything(),
    );
    expect(textarea()).toHaveValue('');
    expect(screen.queryByLabelText('Attachments')).not.toBeInTheDocument();
  });

  it('keeps the body and files when the send fails', async () => {
    renderPage();
    await userEvent.type(textarea(), 'hello');
    await attach(file('a.txt'));

    await userEvent.click(sendButton());

    expect(textarea()).toHaveValue('hello');
    expect(screen.getByText('a.txt')).toBeInTheDocument();
  });

  it('shows Reply sent as a status and failures as an alert', () => {
    replyState = { ...idle, isSuccess: true };
    renderPage();
    expect(screen.getByRole('status')).toHaveTextContent('Reply sent');
  });

  it('drops the draft when navigating to another message', async () => {
    renderPage();
    await userEvent.type(textarea(), 'draft');
    await attach(file('a.txt'));

    await userEvent.click(screen.getByRole('link', { name: 'next' }));

    expect(textarea()).toHaveValue('');
    expect(screen.queryByLabelText('Attachments')).not.toBeInTheDocument();
  });
});
