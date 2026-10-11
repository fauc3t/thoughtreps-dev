import {
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor,
} from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { setWaitlistJoined } from '../waitlistStore';
import { WAITLIST_URL, WaitlistForm } from './WaitlistForm';

const INVALID_COPY = 'Check the address: it needs an @ and a domain.';

beforeEach(() => {
  setWaitlistJoined(null);
});

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
    [400, INVALID_COPY],
    [429, 'Too many tries. Wait a minute and try again.'],
    [500, 'Something went wrong. Try again, or email hello@thoughtreps.com.'],
  ])('shows the message for status %i', async (status, text) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ status }));
    render(<WaitlistForm />);
    fill('a@b.co');
    expect((await screen.findByRole('alert')).textContent).toContain(text);
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
    expect(screen.getByRole('alert').textContent).toContain(INVALID_COPY);
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

  it('asks for an email on an empty submit and marks the input', () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    render(<WaitlistForm />);
    fireEvent.click(screen.getByRole('button', { name: 'Notify me' }));
    const alert = screen.getByRole('alert');
    expect(alert.textContent).toContain('Enter your email first.');
    const input = screen.getByLabelText('Email');
    expect(input.getAttribute('aria-invalid')).toBe('true');
    expect(input.getAttribute('aria-describedby')).toContain(alert.id);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('renders the message right after the input row, before the checkbox', () => {
    render(<WaitlistForm />);
    fireEvent.click(screen.getByRole('button', { name: 'Notify me' }));
    const row = screen.getByLabelText('Email').parentElement!;
    expect(row.nextElementSibling).toBe(screen.getByRole('alert'));
  });

  it('shows the hint and a visible label, and announces success politely', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ status: 200 }));
    render(<WaitlistForm />);
    const hint = screen.getByText(/Then we delete your address/);
    expect(hint.className).not.toContain('sr-only');
    expect(screen.getByText('Email').className).not.toContain('sr-only');
    fill('a@b.co');
    const box = (await screen.findByText(/You're on the list/)).closest(
      '[tabindex]',
    )!;
    expect(box.closest('[role=status]')!.getAttribute('aria-live')).toBe(
      'polite',
    );
  });

  it('shows the joined state in every form after one signs up', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ status: 200 }));
    render(
      <>
        <WaitlistForm inputId="one" />
        <WaitlistForm inputId="two" />
      </>,
    );
    fireEvent.change(document.getElementById('one')!, {
      target: { value: 'a@b.co' },
    });
    fireEvent.click(screen.getAllByRole('button', { name: 'Notify me' })[0]);
    await waitFor(() =>
      expect(screen.getAllByText(/You're on the list/)).toHaveLength(2),
    );
    expect(screen.queryByRole('button', { name: 'Notify me' })).toBeNull();
    const [first, second] = screen.getAllByRole('status');
    expect(first.getAttribute('aria-live')).toBe('polite');
    expect(second.getAttribute('aria-live')).toBe('off');
    expect(document.activeElement).toBe(first.firstElementChild);
  });

  it('shows the address in a new form while it is in memory', () => {
    setWaitlistJoined({ email: 'kept@b.co', beta: false });
    render(<WaitlistForm />);
    expect(screen.getByText(/kept@b.co/)).toBeTruthy();
  });

  it('uses generic copy when only the joined flag is known', () => {
    setWaitlistJoined({ email: null, beta: false });
    render(<WaitlistForm />);
    expect(
      screen.getByText(
        "You're on the list. We'll email you when Thought Reps launches.",
      ),
    ).toBeTruthy();
  });

  it('still works when sessionStorage throws', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ status: 200 }));
    const spy = vi
      .spyOn(Storage.prototype, 'setItem')
      .mockImplementation(() => {
        throw new Error('blocked');
      });
    render(<WaitlistForm />);
    fill('a@b.co');
    expect(await screen.findByText(/You're on the list/)).toBeTruthy();
    spy.mockRestore();
  });
});
