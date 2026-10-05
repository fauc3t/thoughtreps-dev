import { MemoryRouter } from 'react-router-dom';
import { render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi, beforeEach } from 'vitest';
import App from './App';
import { getCurrentSession } from './lib/auth';

vi.mock('./lib/auth', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./lib/auth')>();
  return { ...actual, getCurrentSession: vi.fn() };
});

beforeEach(() => {
  vi.mocked(getCurrentSession).mockReset();
});

describe('protected routes', () => {
  it('redirects to /login when there is no session', async () => {
    vi.mocked(getCurrentSession).mockResolvedValue(null);

    render(
      <MemoryRouter initialEntries={['/']}>
        <App />
      </MemoryRouter>,
    );

    await waitFor(() =>
      expect(
        screen.getByRole('heading', { name: 'Sign in' }),
      ).toBeInTheDocument(),
    );
  });
});
