import { S3Client } from '@aws-sdk/client-s3';
import { S3ObjectStore, objectKey } from './objects.js';

const SHA = Buffer.alloc(32, 7).toString('base64');

function store() {
  const s3 = new S3Client({
    region: 'us-east-1',
    credentials: { accessKeyId: 'AKIAEXAMPLE', secretAccessKey: 'secret' },
  });
  return new S3ObjectStore(s3, 'bucket');
}

describe('S3ObjectStore presigned URLs', () => {
  it('signs content-length and the SHA-256 checksum as headers the client must send', async () => {
    const { url, headers } = await store().presignPut(objectKey('abc'), {
      sizeBytes: 1234,
      sha256: SHA,
      expiresInSeconds: 600,
    });
    const parsed = new URL(url);
    expect(parsed.pathname).toBe('/exports/abc');
    expect(parsed.searchParams.get('X-Amz-Expires')).toBe('600');
    expect(parsed.searchParams.get('X-Amz-SignedHeaders')).toBe(
      'content-length;host;x-amz-checksum-sha256',
    );
    expect(parsed.searchParams.has('x-amz-checksum-sha256')).toBe(false);
    expect(headers).toEqual({
      'content-length': '1234',
      'x-amz-checksum-sha256': SHA,
    });
  });

  it('presigns GETs for the same key', async () => {
    const url = await store().presignGet(objectKey('abc'), 300);
    const parsed = new URL(url);
    expect(parsed.pathname).toBe('/exports/abc');
    expect(parsed.searchParams.get('X-Amz-Expires')).toBe('300');
  });
});
