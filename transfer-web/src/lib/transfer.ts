import { decryptExport, FormatError, sha256Base64 } from './crypto';
import { hasExportMimetype } from './zip';

export type TransferFailure =
  | 'download'
  | 'integrity'
  | 'format'
  | 'decrypt'
  | 'not_export';

export class TransferError extends Error {
  constructor(readonly failure: TransferFailure) {
    super(failure);
  }
}

export type Phase = 'downloading' | 'verifying' | 'decrypting';

export interface Download {
  url: string;
  sizeBytes: number;
  sha256: string;
}

async function fetchCiphertext(
  { url, sizeBytes }: Download,
  onProgress: (loaded: number) => void,
): Promise<Uint8Array> {
  const buffer = new Uint8Array(sizeBytes);
  let loaded = 0;
  try {
    const response = await fetch(url);
    if (!response.ok || !response.body) throw new TransferError('download');
    const reader = response.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (loaded + value.length > sizeBytes) {
        throw new TransferError('download');
      }
      buffer.set(value, loaded);
      loaded += value.length;
      onProgress(loaded);
    }
  } catch (err) {
    throw err instanceof TransferError ? err : new TransferError('download');
  }
  if (loaded !== sizeBytes) throw new TransferError('download');
  return buffer;
}

export async function downloadAndDecrypt(
  download: Download,
  key: string,
  onPhase: (phase: Phase) => void,
  onProgress: (loaded: number) => void,
): Promise<ArrayBuffer> {
  onPhase('downloading');
  const ciphertext = await fetchCiphertext(download, onProgress);

  onPhase('verifying');
  if ((await sha256Base64(ciphertext)) !== download.sha256) {
    throw new TransferError('integrity');
  }

  onPhase('decrypting');
  let zip: ArrayBuffer;
  try {
    zip = await decryptExport(ciphertext, key);
  } catch (err) {
    throw new TransferError(err instanceof FormatError ? 'format' : 'decrypt');
  }
  if (!hasExportMimetype(new Uint8Array(zip))) throw new TransferError('not_export');
  return zip;
}
