const MIMETYPE = 'application/vnd.thoughtreps.export+zip';

export function bytesToBase64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

export function makeZip(
  options: { name?: string; extra?: number; descriptorNext?: number } = {},
) {
  const name = new TextEncoder().encode(options.name ?? 'mimetype');
  const data = new TextEncoder().encode(MIMETYPE);
  const extra = options.extra ?? 0;
  const trailer = options.descriptorNext === undefined ? 8 : 20;
  const out = new Uint8Array(30 + name.length + extra + data.length + trailer);
  const view = new DataView(out.buffer);
  view.setUint32(0, 0x04034b50, true);
  view.setUint16(4, 20, true);
  view.setUint32(18, data.length, true);
  view.setUint32(22, data.length, true);
  view.setUint16(26, name.length, true);
  view.setUint16(28, extra, true);
  out.set(name, 30);
  out.set(data, 30 + name.length + extra);
  if (options.descriptorNext !== undefined) {
    const dataEnd = 30 + name.length + extra + data.length;
    view.setUint16(6, 8, true);
    view.setUint32(18, 0, true);
    view.setUint32(22, 0, true);
    view.setUint32(dataEnd, 0x08074b50, true);
    view.setUint32(dataEnd + 16, options.descriptorNext, true);
  }
  return out;
}

export async function encryptExport(plaintext: Uint8Array) {
  const raw = crypto.getRandomValues(new Uint8Array(32));
  const key = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, [
    'encrypt',
  ]);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, plaintext),
  );
  const file = new Uint8Array(4 + 12 + sealed.length);
  file.set(new TextEncoder().encode('TRB1'), 0);
  file.set(nonce, 4);
  file.set(sealed, 16);
  return { file, key: bytesToBase64url(raw) };
}
