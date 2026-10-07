import {
  DeleteObjectCommand,
  GetObjectCommand,
  HeadObjectCommand,
  S3Client,
} from '@aws-sdk/client-s3';
import { SendEmailCommand, SESv2Client } from '@aws-sdk/client-sesv2';

const MAX = 25 * 1024 * 1024;
const ADDRESS = 'hello@example.test';
const MAIL_KEY = `${ADDRESS}/inbox/abc`;

const ORIGINAL = Buffer.from(
  [
    'From: Sender <sender@example.test>',
    'To: hello@example.test',
    'Subject: Hello',
    'Message-ID: <orig@example.test>',
    '',
    'hi',
  ].join('\r\n'),
);

type Handler = typeof import('./index.js').handler;
let handler: Handler;

let objectSizes: Record<string, number>;
let deleteFails: boolean;
let s3Calls: unknown[];
let sesCalls: SendEmailCommand[];

function body(bytes: Uint8Array) {
  return { transformToByteArray: async () => bytes };
}

beforeAll(async () => {
  process.env.MAIL_BUCKET_NAME = 'mail-test';
  process.env.ATTACHMENT_BUCKET_NAME = 'attachments-test';
  process.env.MAILBOX_ADDRESSES = `${ADDRESS},support@example.test`;
  ({ handler } = await import('./index.js'));
});

beforeEach(() => {
  objectSizes = { [`${ADDRESS}/u1`]: 5, [`${ADDRESS}/u2`]: 5 };
  deleteFails = false;
  s3Calls = [];
  sesCalls = [];
  jest.spyOn(console, 'error').mockImplementation(() => undefined);
  jest.spyOn(S3Client.prototype, 'send').mockImplementation((async (
    command: unknown,
  ) => {
    s3Calls.push(command);
    if (command instanceof GetObjectCommand) {
      const { Bucket, Key } = command.input;
      if (Bucket === 'mail-test') return { Body: body(ORIGINAL) };
      return { Body: body(Buffer.alloc(objectSizes[Key as string], 7)) };
    }
    if (command instanceof HeadObjectCommand) {
      const size = objectSizes[command.input.Key as string];
      if (size === undefined) throw new Error('Forbidden');
      return { ContentLength: size };
    }
    if (command instanceof DeleteObjectCommand) {
      if (deleteFails) throw new Error('delete failed');
      return {};
    }
    throw new Error('unexpected command');
  }) as never);
  jest.spyOn(SESv2Client.prototype, 'send').mockImplementation((async (
    command: SendEmailCommand,
  ) => {
    sesCalls.push(command);
    return { MessageId: 'ses-1' };
  }) as never);
});

afterEach(() => {
  jest.restoreAllMocks();
});

function call(overrides: Record<string, unknown> = {}) {
  return handler({
    body: JSON.stringify({
      address: ADDRESS,
      key: MAIL_KEY,
      body: 'thanks',
      ...overrides,
    }),
  });
}

const att = (key: string, filename = 'a.txt') => ({
  key,
  filename,
  contentType: 'text/plain',
});

describe('reply handler', () => {
  it('sends a plain reply through SES v2 raw content with FromEmailAddress and no attachment S3 calls', async () => {
    const result = await call();
    expect(result.statusCode).toBe(200);
    expect(JSON.parse(result.body)).toEqual({ messageId: 'ses-1' });
    expect(sesCalls).toHaveLength(1);
    const input = sesCalls[0].input;
    expect(input.FromEmailAddress).toBe(ADDRESS);
    expect(input.Destination).toEqual({ ToAddresses: ['sender@example.test'] });
    expect(input.Content?.Raw?.Data).toBeInstanceOf(Uint8Array);
    expect(
      s3Calls.filter((c) => !(c instanceof GetObjectCommand)),
    ).toHaveLength(0);
  });

  it('attaches the uploaded files, then deletes them after a successful send', async () => {
    const result = await call({
      attachments: [att(`${ADDRESS}/u1`), att(`${ADDRESS}/u2`, 'b.txt')],
    });
    expect(result.statusCode).toBe(200);
    const raw = Buffer.from(
      sesCalls[0].input.Content?.Raw?.Data as Uint8Array,
    ).toString('utf-8');
    expect(raw).toContain('multipart/mixed');
    expect(raw).toContain('filename="a.txt"');
    expect(raw).toContain('filename="b.txt"');
    const deleted = s3Calls
      .filter((c): c is DeleteObjectCommand => c instanceof DeleteObjectCommand)
      .map((c) => [c.input.Bucket, c.input.Key]);
    expect(deleted).toEqual([
      ['attachments-test', `${ADDRESS}/u1`],
      ['attachments-test', `${ADDRESS}/u2`],
    ]);
  });

  it('allows an empty body when there is an attachment', async () => {
    const result = await call({
      body: '  \n',
      attachments: [att(`${ADDRESS}/u1`)],
    });
    expect(result.statusCode).toBe(200);
  });

  it('rejects an empty body with no attachments', async () => {
    for (const attachments of [undefined, []]) {
      const result = await call({ body: ' ', attachments });
      expect(result.statusCode).toBe(400);
      expect(JSON.parse(result.body)).toEqual({ error: expect.any(String) });
    }
    expect(sesCalls).toHaveLength(0);
  });

  it('still returns 200 when deleting an attachment fails', async () => {
    deleteFails = true;
    const result = await call({ attachments: [att(`${ADDRESS}/u1`)] });
    expect(result.statusCode).toBe(200);
    expect(JSON.parse(result.body)).toEqual({ messageId: 'ses-1' });
    expect(console.error).toHaveBeenCalled();
  });

  it('rejects an attachment key outside the request address with 400, before touching S3', async () => {
    const result = await call({
      attachments: [att('support@example.test/u1')],
    });
    expect(result.statusCode).toBe(400);
    expect(s3Calls).toHaveLength(0);
    expect(sesCalls).toHaveLength(0);
  });

  it('rejects a key that only prefix-matches a different address', async () => {
    const result = await call({
      attachments: [att('hello@example.test.evil/u1')],
    });
    expect(result.statusCode).toBe(400);
  });

  it('returns 400 naming the file when an attachment is missing, and sends nothing', async () => {
    const result = await call({
      attachments: [att(`${ADDRESS}/u1`), att(`${ADDRESS}/gone`, 'gone.txt')],
    });
    expect(result.statusCode).toBe(400);
    expect(JSON.parse(result.body)).toEqual({
      error: 'Attachment not found: gone.txt',
    });
    expect(sesCalls).toHaveLength(0);
    expect(s3Calls.some((c) => c instanceof DeleteObjectCommand)).toBe(false);
  });

  it('returns 413 when the attachments total more than 25 MiB, without downloading them', async () => {
    objectSizes[`${ADDRESS}/u1`] = MAX;
    objectSizes[`${ADDRESS}/u2`] = 1;
    const result = await call({
      attachments: [att(`${ADDRESS}/u1`), att(`${ADDRESS}/u2`)],
    });
    expect(result.statusCode).toBe(413);
    expect(JSON.parse(result.body)).toEqual({ error: expect.any(String) });
    expect(
      s3Calls.some(
        (c) =>
          c instanceof GetObjectCommand &&
          c.input.Bucket === 'attachments-test',
      ),
    ).toBe(false);
  });

  it('returns 413 when the downloaded bytes exceed 25 MiB even though HeadObject reported less', async () => {
    jest.mocked(S3Client.prototype.send).mockImplementation((async (
      command: unknown,
    ) => {
      s3Calls.push(command);
      if (command instanceof HeadObjectCommand) return { ContentLength: 5 };
      if (command instanceof GetObjectCommand) {
        if (command.input.Bucket === 'mail-test')
          return { Body: body(ORIGINAL) };
        return { Body: body(Buffer.alloc(MAX + 1)) };
      }
      return {};
    }) as never);
    const result = await call({ attachments: [att(`${ADDRESS}/u1`)] });
    expect(result.statusCode).toBe(413);
    expect(sesCalls).toHaveLength(0);
  });

  it('rejects an attachment filename over 255 characters with 400', async () => {
    const result = await call({
      attachments: [att(`${ADDRESS}/u1`, 'a'.repeat(256))],
    });
    expect(result.statusCode).toBe(400);
    expect(s3Calls).toHaveLength(0);
    const ok = await call({
      attachments: [att(`${ADDRESS}/u1`, 'a'.repeat(255))],
    });
    expect(ok.statusCode).toBe(200);
  });

  it('accepts exactly 25 MiB in total', async () => {
    objectSizes[`${ADDRESS}/u1`] = MAX;
    delete objectSizes[`${ADDRESS}/u2`];
    const result = await call({ attachments: [att(`${ADDRESS}/u1`)] });
    expect(result.statusCode).toBe(200);
  });

  it('rejects more than 10 attachments and malformed attachment entries', async () => {
    const eleven = Array.from({ length: 11 }, () => att(`${ADDRESS}/u1`));
    expect((await call({ attachments: eleven })).statusCode).toBe(400);
    expect((await call({ attachments: 'x' })).statusCode).toBe(400);
    expect(
      (await call({ attachments: [{ key: `${ADDRESS}/u1` }] })).statusCode,
    ).toBe(400);
  });

  it('keeps the attachments for a retry when SES fails', async () => {
    jest
      .spyOn(SESv2Client.prototype, 'send')
      .mockRejectedValue(new Error('ses down') as never);
    const result = await call({ attachments: [att(`${ADDRESS}/u1`)] });
    expect(result.statusCode).toBe(502);
    expect(s3Calls.some((c) => c instanceof DeleteObjectCommand)).toBe(false);
  });

  it('rejects an unknown address and a key outside the address inbox', async () => {
    expect((await call({ address: 'evil@example.test' })).statusCode).toBe(400);
    expect(
      (await call({ key: 'support@example.test/inbox/x' })).statusCode,
    ).toBe(400);
  });
});
