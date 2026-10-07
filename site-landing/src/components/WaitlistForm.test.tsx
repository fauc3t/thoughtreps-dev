import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { WAITLIST_URL, WaitlistForm } from './WaitlistForm';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

function fill(email: string, beta = false) {
  fireEvent.change(screen.getByLabelText('Email'), {
    target: { value: email },
  });
  if (beta) fireEvent.click(screen.getByLabelText(/TestFlight invite/));
  fireEvent.click(screen.getByRole('button', { name: 'Notify me' }));
}

describe('WaitlistForm', () => {
  it('posts the email and shows success with focus', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ status: 200 });
    vi.stubGlobal('fetch', fetchMock);
    render(<WaitlistForm />);
    fill('a@b.co', true);
    const status = await screen.findByText(/You're on the list/);
    const box = status.closest('[tabindex]')!;
    expect(box.textContent).toContain('a@b.co');
    expect(box.textContent).toContain('TestFlight');
    expect(document.activeElement).toBe(box);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe(WAITLIST_URL);
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
      email: 'a@b.co',
      beta: true,
      honeypot: '',
    });
  });

  it.each([
    [400, "That email doesn't look right."],
    [429, 'Too many tries. Wait a minute and try again.'],
    [500, 'Something went wrong. Try again, or email hello@thoughtreps.com.'],
  ])('shows the message for status %i', async (status, text) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ status }));
    render(<WaitlistForm />);
    fill('a@b.co');
    expect((await screen.findByRole('alert')).textContent).toBe(text);
    const input = screen.getByLabelText('Email');
    expect(input.getAttribute('aria-describedby')).toContain(
      screen.getByRole('alert').id,
    );
  });

  it('shows a generic error on network failure', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('offline')));
    render(<WaitlistForm />);
    fill('a@b.co');
    await waitFor(() =>
      expect(screen.getByRole('alert').textContent).toContain('went wrong'),
    );
  });

  it('skips the request when the honeypot is filled', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const { container } = render(<WaitlistForm />);
    const trap = container.querySelector<HTMLInputElement>(
      'input[name=website_url]',
    )!;
    fireEvent.change(trap, { target: { value: 'spam' } });
    fill('a@b.co');
    expect(await screen.findByText(/You're on the list/)).toBeTruthy();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('trims the email in the request body', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ status: 200 });
    vi.stubGlobal('fetch', fetchMock);
    render(<WaitlistForm />);
    fill('  a@b.co  ');
    await screen.findByText(/You're on the list/);
    expect(JSON.parse(fetchMock.mock.calls[0][1].body).email).toBe('a@b.co');
  });

  it('flags the input invalid and refocuses it on a 400', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ status: 400 }));
    render(<WaitlistForm />);
    fill('a@b.co');
    await screen.findByRole('alert');
    const input = screen.getByLabelText('Email');
    expect(input.getAttribute('aria-invalid')).toBe('true');
    expect(document.activeElement).toBe(input);
  });

  it('validates client-side without calling the API', () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    render(<WaitlistForm />);
    fill('nope');
    expect(screen.getByRole('alert').textContent).toBe(
      "That email doesn't look right.",
    );
    expect(screen.getByLabelText('Email').getAttribute('aria-invalid')).toBe(
      'true',
    );
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('sends only one request on a double submit', async () => {
    let resolve: (v: { status: number }) => void = () => {};
    const fetchMock = vi.fn(
      () => new Promise((r) => (resolve = r as typeof resolve)),
    );
    vi.stubGlobal('fetch', fetchMock);
    render(<WaitlistForm />);
    fill('a@b.co');
    fireEvent.click(screen.getByRole('button', { name: 'Adding you...' }));
    fireEvent.submit(screen.getByLabelText('Email').closest('form')!);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    resolve({ status: 200 });
    await screen.findByText(/You're on the list/);
  });
});
