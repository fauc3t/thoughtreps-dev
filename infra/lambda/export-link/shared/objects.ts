import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  PutObjectCommand,
  S3ServiceException,
  type S3Client,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

export const objectKey = (exportLinkId: string) => `exports/${exportLinkId}`;

export interface ObjectStore {
  presignPut(
    key: string,
    upload: { sizeBytes: number; sha256: string; expiresInSeconds: number },
  ): Promise<{ url: string; headers: Record<string, string> }>;
  presignGet(key: string, expiresInSeconds: number): Promise<string>;
  head(key: string): Promise<{ sizeBytes: number; sha256?: string } | null>;
  delete(key: string): Promise<void>;
}

const CHECKSUM_HEADER = 'x-amz-checksum-sha256';

export class S3ObjectStore implements ObjectStore {
  constructor(
    private readonly s3: S3Client,
    private readonly bucket: string,
  ) {}

  // Both headers are signed (not hoisted into the query string), so S3
  // rejects an upload whose length differs from what was recorded and
  // verifies the body against the SHA-256 before storing it.
  async presignPut(
    key: string,
    upload: { sizeBytes: number; sha256: string; expiresInSeconds: number },
  ) {
    const url = await getSignedUrl(
      this.s3,
      new PutObjectCommand({
        Bucket: this.bucket,
        Key: key,
        ContentLength: upload.sizeBytes,
        ChecksumSHA256: upload.sha256,
      }),
      {
        expiresIn: upload.expiresInSeconds,
        signableHeaders: new Set(['content-length', CHECKSUM_HEADER]),
        unhoistableHeaders: new Set([CHECKSUM_HEADER]),
      },
    );
    return {
      url,
      headers: {
        'content-length': String(upload.sizeBytes),
        [CHECKSUM_HEADER]: upload.sha256,
      },
    };
  }

  presignGet(key: string, expiresInSeconds: number) {
    return getSignedUrl(
      this.s3,
      new GetObjectCommand({ Bucket: this.bucket, Key: key }),
      { expiresIn: expiresInSeconds },
    );
  }

  // The Lambda role has no s3:ListBucket, so S3 answers 403 rather than 404
  // for a missing key; both mean "nothing was uploaded".
  async head(key: string) {
    try {
      const out = await this.s3.send(
        new HeadObjectCommand({
          Bucket: this.bucket,
          Key: key,
          ChecksumMode: 'ENABLED',
        }),
      );
      return { sizeBytes: out.ContentLength ?? -1, sha256: out.ChecksumSHA256 };
    } catch (err) {
      if (
        err instanceof S3ServiceException &&
        (err.$metadata.httpStatusCode === 404 ||
          err.$metadata.httpStatusCode === 403)
      ) {
        return null;
      }
      throw err;
    }
  }

  async delete(key: string) {
    await this.s3.send(
      new DeleteObjectCommand({ Bucket: this.bucket, Key: key }),
    );
  }
}
