import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { App } from './App';
import { parseLink } from './lib/link';
import { sha256Base64 } from './lib/crypto';
import { encryptExport, makeZip } from './test/fixture';

const ID = 'AAAAAAAAAAAAAAAAAAAAAA';
const S3_URL = 'https://bucket.s3.amazonaws.com/exports/x?sig=1';
const API = `/api/v1/export-links/${ID}`;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status });

const READY = {
  status: 'ready',
  sizeBytes: 1_572_864,
  expiresAt: '2026-10-06T12:00:00.000Z',
};

let fetchMock: ReturnType<typeof vi.fn>;
let clickSpy: ReturnType<typeof vi.spyOn>;

function calls(suffix: string) {
  return fetchMock.mock.calls.filter(([url]) => url === `${API}${suffix}`);
}

function renderLink(key: string) {
  render(<App link={parseLink(`/x/${ID}`, `#${key}`)} />);
}

const FUTURE = () => new Date(Date.now() + 5 * 60_000).toISOString();
const PAST = () => new Date(Date.now() - 60_000).toISOString();

async function serveSuccessfulDownload(
  key: string,
  ciphertext: Uint8Array,
  expiresAt: string = FUTURE(),
) {
  fetchMock.mockImplementation(async (url: string, init?: RequestInit) => {
    if (url === API) return json(200, READY);
    if (url === `${API}/claim` && init?.method === 'POST') {
      return json(200, {
        download: { url: S3_URL, expiresAt },
        sizeBytes: ciphertext.length,
        sha256: await sha256Base64(ciphertext),
      });
    }
    if (url === S3_URL) return new Response(ciphertext);
    if (url === `${API}/done`) return new Response(null, { status: 204 });
    throw new Error(`unexpected fetch ${url} for key ${key}`);
  });
}

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
  URL.createObjectURL = vi.fn(() => 'blob:fake');
  URL.revokeObjectURL = vi.fn();
  clickSpy = vi
    .spyOn(HTMLAnchorElement.prototype, 'click')
    .mockImplementation(() => {});
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('App', () => {
  it('shows the incomplete-link message without any request', () => {
    render(<App link={parseLink(`/x/${ID}`, '')} />);
    expect(
      screen.getByText(/This link is incomplete — copy the whole link/),
    ).toBeTruthy();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('looks up status on load without claiming', async () => {
    fetchMock.mockResolvedValue(json(200, READY));
    renderLink('A'.repeat(43));
    expect(await screen.findByText('Your export is ready.')).toBeTruthy();
    expect(screen.getByText(/1\.5 MB/)).toBeTruthy();
    expect(screen.getByText(/works once/)).toBeTruthy();
    expect(calls('/claim')).toHaveLength(0);
  });

  it.each([
    ['used', 'This link has already been used.'],
    ['expired', 'This link has expired.'],
    ['revoked', 'This link was cancelled.'],
  ])('shows the %s state', async (status, copy) => {
    fetchMock.mockResolvedValue(json(200, { status }));
    renderLink('A'.repeat(43));
    expect(await screen.findByText(copy)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Download' })).toBeNull();
  });

  it('shows not found for a 404', async () => {
    fetchMock.mockResolvedValue(
      json(404, { error: 'not_found', message: 'Unknown export link' }),
    );
    renderLink('A'.repeat(43));
    expect(await screen.findByText(/couldn’t find this link/)).toBeTruthy();
  });

  it('offers a retry on network failure', async () => {
    fetchMock.mockRejectedValueOnce(new TypeError('offline'));
    fetchMock.mockResolvedValue(json(200, READY));
    renderLink('A'.repeat(43));
    expect(await screen.findByText(/couldn’t reach the server/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
    expect(await screen.findByText('Your export is ready.')).toBeTruthy();
  });

  it('downloads, decrypts, saves and marks the link done', async () => {
    const { file, key } = await encryptExport(makeZip());
    await serveSuccessfulDownload(key, file);
    renderLink(key);

    fireEvent.click(await screen.findByRole('button', { name: 'Download' }));

    expect(await screen.findByText('Saved.')).toBeTruthy();
    expect(screen.getByText(/now used up/)).toBeTruthy();
    expect(clickSpy).toHaveBeenCalledTimes(1);
    expect(calls('/claim')).toHaveLength(1);
    expect(calls('/done')).toHaveLength(1);
    const blob = vi.mocked(URL.createObjectURL).mock.calls[0]?.[0] as Blob;
    expect(blob.type).toBe('application/vnd.thoughtreps.export+zip');
  });

  it('reports a wrong key and does not call done', async () => {
    const { file } = await encryptExport(makeZip());
    await serveSuccessfulDownload('B'.repeat(43), file);
    renderLink('B'.repeat(43));

    fireEvent.click(await screen.findByRole('button', { name: 'Download' }));

    expect(await screen.findByText(/couldn’t unlock the file/)).toBeTruthy();
    expect(screen.getByText(/now used up/)).toBeTruthy();
    expect(clickSpy).not.toHaveBeenCalled();
    expect(calls('/done')).toHaveLength(0);
  });

  it('rejects a file whose hash does not match', async () => {
    const { file, key } = await encryptExport(makeZip());
    await serveSuccessfulDownload(key, file);
    const serve = fetchMock.getMockImplementation()!;
    fetchMock.mockImplementation(async (url: string, init?: RequestInit) =>
      url === S3_URL
        ? new Response(new Uint8Array(file.length))
        : serve(url, init),
    );
    renderLink(key);

    fireEvent.click(await screen.findByRole('button', { name: 'Download' }));

    expect(await screen.findByText(/downloaded file was damaged/)).toBeTruthy();
    expect(calls('/done')).toHaveLength(0);
  });

  it('retries the same URL without re-claiming while it is still valid', async () => {
    const { file, key } = await encryptExport(makeZip());
    await serveSuccessfulDownload(key, file);
    const serve = fetchMock.getMockImplementation()!;
    let s3Calls = 0;
    fetchMock.mockImplementation(async (url: string, init?: RequestInit) => {
      if (url === S3_URL && s3Calls++ === 0) {
        throw new TypeError('Failed to fetch');
      }
      return serve(url, init);
    });
    renderLink(key);

    fireEvent.click(await screen.findByRole('button', { name: 'Download' }));

    expect(await screen.findByText(/download didn’t finish/)).toBeTruthy();
    expect(screen.getByText(/too large for this browser/)).toBeTruthy();
    expect(screen.queryByText(/now used up/)).toBeNull();
    expect(calls('/done')).toHaveLength(0);

    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

    expect(await screen.findByText('Saved.')).toBeTruthy();
    expect(calls('/claim')).toHaveLength(1);
    expect(s3Calls).toBe(2);
    expect(calls('/done')).toHaveLength(1);
  });

  it('says the link is used up when the download URL has expired', async () => {
    const { file, key } = await encryptExport(makeZip());
    await serveSuccessfulDownload(key, file, PAST());
    const serve = fetchMock.getMockImplementation()!;
    fetchMock.mockImplementation(async (url: string, init?: RequestInit) => {
      if (url === S3_URL) throw new TypeError('Failed to fetch');
      return serve(url, init);
    });
    renderLink(key);

    fireEvent.click(await screen.findByRole('button', { name: 'Download' }));

    expect(await screen.findByText(/download didn’t finish/)).toBeTruthy();
    expect(screen.getByText(/now used up/)).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull();
  });

  it('moves focus to the status heading when the download starts', async () => {
    const { file, key } = await encryptExport(makeZip());
    await serveSuccessfulDownload(key, file);
    renderLink(key);

    fireEvent.click(await screen.findByRole('button', { name: 'Download' }));

    expect(await screen.findByText('Saved.')).toBeTruthy();
    expect(document.activeElement?.tagName).toBe('H2');
  });

  it('shows used when the claim loses the race', async () => {
    fetchMock.mockImplementation(async (url: string) =>
      url === API
        ? json(200, READY)
        : json(410, { error: 'used', message: 'Export link is used' }),
    );
    renderLink('A'.repeat(43));

    fireEvent.click(await screen.findByRole('button', { name: 'Download' }));

    expect(
      await screen.findByText('This link has already been used.'),
    ).toBeTruthy();
  });

  it('lets the user retry when the claim request fails to send', async () => {
    fetchMock.mockImplementation(async (url: string) => {
      if (url === API) return json(200, READY);
      throw new TypeError('offline');
    });
    renderLink('A'.repeat(43));

    fireEvent.click(await screen.findByRole('button', { name: 'Download' }));

    expect(await screen.findByRole('alert')).toBeTruthy();
    expect(
      (screen.getByRole('button', { name: 'Download' }) as HTMLButtonElement)
        .disabled,
    ).toBe(false);
  });
});
