const MAX = 25 * 1024 * 1024;

type Handler = typeof import('./index.js').handler;
let handler: Handler;

beforeAll(async () => {
  process.env.ATTACHMENT_BUCKET_NAME = 'attachments-test';
  process.env.MAILBOX_ADDRESSES = 'hello@example.test, support@example.test';
  process.env.AWS_REGION = 'us-east-1';
  process.env.AWS_ACCESS_KEY_ID = 'AKIAIOSFODNN7EXAMPLE';
  process.env.AWS_SECRET_ACCESS_KEY = 'secret';
  ({ handler } = await import('./index.js'));
});

function call(body: unknown) {
  return handler({
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

const valid = {
  address: 'hello@example.test',
  filename: 'report.pdf',
  contentType: 'application/pdf',
  size: 1234,
};

describe('attachments handler', () => {
  it('returns a presigned POST pinned to a random key under the address', async () => {
    const result = await call(valid);
    expect(result.statusCode).toBe(200);
    const { key, url, fields } = JSON.parse(result.body) as {
      key: string;
      url: string;
      fields: Record<string, string>;
    };
    expect(key).toMatch(/^hello@example\.test\/[0-9a-f-]{36}$/);
    expect(key).not.toContain('report');
    expect(url).toContain('attachments-test');
    expect(fields.key).toBe(key);
    expect(fields['Content-Type']).toBe('application/pdf');

    const policy = JSON.parse(
      Buffer.from(fields.Policy, 'base64').toString('utf-8'),
    ) as { expiration: string; conditions: unknown[] };
    expect(policy.conditions).toEqual(
      expect.arrayContaining([
        ['content-length-range', 1, MAX],
        { key },
        { 'Content-Type': 'application/pdf' },
        { bucket: 'attachments-test' },
      ]),
    );
    const ttl = Date.parse(policy.expiration) - Date.now();
    expect(ttl).toBeGreaterThan(14 * 60 * 1000);
    expect(ttl).toBeLessThanOrEqual(15 * 60 * 1000);
  });

  it('falls back to application/octet-stream for an invalid content type', async () => {
    const result = await call({ ...valid, contentType: 'text/html; x=y' });
    const { fields } = JSON.parse(result.body) as {
      fields: Record<string, string>;
    };
    expect(fields['Content-Type']).toBe('application/octet-stream');
  });

  it.each([
    ['malformed JSON', '{nope'],
    ['empty body', ''],
    ['missing field', { ...valid, size: undefined }],
    ['string size', { ...valid, size: '10' }],
    ['unknown address', { ...valid, address: 'evil@example.test' }],
    ['empty filename', { ...valid, filename: '' }],
    ['filename over 255', { ...valid, filename: 'a'.repeat(256) }],
    ['size 0', { ...valid, size: 0 }],
    ['negative size', { ...valid, size: -1 }],
    ['fractional size', { ...valid, size: 1.5 }],
    ['size over 25 MiB', { ...valid, size: MAX + 1 }],
  ])('rejects %s with 400 and an { error }', async (_name, body) => {
    const result = await call(body);
    expect(result.statusCode).toBe(400);
    expect(JSON.parse(result.body)).toEqual({ error: expect.any(String) });
  });

  it('accepts the boundary values 1 byte, 25 MiB and a 255-character filename', async () => {
    for (const override of [
      { size: 1 },
      { size: MAX },
      { filename: 'a'.repeat(255) },
    ]) {
      const result = await call({ ...valid, ...override });
      expect(result.statusCode).toBe(200);
    }
  });
});
