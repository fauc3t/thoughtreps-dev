import { GetObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { SendRawEmailCommand, SESClient } from '@aws-sdk/client-ses';
import PostalMime from 'postal-mime';
import { inboxPrefix, normalizeAddress } from '../../../lib/mail/inbox.js';
import { buildForwardMessage } from './buildForwardMessage.js';

// A minimal local shape of the pieces of an SES "Invoke Lambda function"
// receipt-rule-action event this handler actually touches — same "don't
// pull in @types/aws-lambda for two field names" convention reply/index.ts
// and delete/index.ts already follow for their own minimal HTTP event
// shapes. This is NOT an S3 event shape (an earlier version of this
// handler was wired to one, via a since-removed S3 event notification —
// see mail-stack.ts's own comment on why that approach was replaced):
// mail-stack.ts now wires ForwardFn as a second action on the receipt
// rule itself, so the event SES invokes this Lambda with is the
// documented SES Lambda-receipt-rule-action shape instead (see
// https://docs.aws.amazon.com/ses/latest/dg/receiving-email-action-lambda-event.html).
// `ses.receipt.recipients` (recipients that actually matched this rule) is
// used rather than `ses.mail.destination` (the raw envelope recipients,
// which can include addresses this rule never matched) — the more
// precisely-scoped of the two per SES's own docs.
interface SesReceiptEventRecord {
  ses: {
    mail: { messageId: string };
    receipt: { recipients: string[] };
  };
}

interface SesReceiptEvent {
  Records?: SesReceiptEventRecord[];
}

const s3 = new S3Client({});
const ses = new SESClient({});

const MAIL_BUCKET_NAME = process.env.MAIL_BUCKET_NAME ?? '';

// Same style reply/index.ts and delete/index.ts use for parsing their own
// comma-separated MAILBOX_ADDRESSES env var — parsed once at module load,
// not per-invocation.
const FORWARD_MAP: Record<string, string> = JSON.parse(
  process.env.FORWARD_MAP ?? '{}',
);

// This Lambda has no caller waiting on a response — it's invoked as a
// receipt-rule action, not a route behind ApiStack's HttpApi (unlike
// ReplyFn/DeleteFn) — so there's no response shape to build here, and each
// record is handled best-effort: a failure on one record is logged and
// skipped rather than thrown, so it doesn't block/fail the rest of the
// batch.
export async function handler(event: SesReceiptEvent): Promise<void> {
  for (const record of event.Records ?? []) {
    try {
      await forwardRecord(record);
    } catch (err) {
      console.error('Failed to forward message', {
        messageId: record.ses.mail.messageId,
        error: err instanceof Error ? err.message : err,
      });
    }
  }
}

async function forwardRecord(record: SesReceiptEventRecord): Promise<void> {
  const { messageId } = record.ses.mail;

  for (const recipient of record.ses.receipt.recipients) {
    const normalizedAddress = normalizeAddress(recipient);
    const forwardToAddress = FORWARD_MAP[normalizedAddress];
    // Not present: shouldn't happen given this rule's own `recipients:
    // [address]` filter (see mail-stack.ts) — a rule only ever matches the
    // one address it was created for — but that filter isn't assumed
    // airtight here either, same defensive posture as before: skip
    // silently rather than erroring on an address this Lambda was never
    // configured to forward.
    if (!forwardToAddress) {
      continue;
    }

    await forwardOne(normalizedAddress, forwardToAddress, messageId);
  }
}

async function forwardOne(
  normalizedAddress: string,
  forwardToAddress: string,
  messageId: string,
): Promise<void> {
  // Reconstructs the same key the receipt rule's S3 action (mail-stack.ts)
  // already wrote this message to — {inboxPrefix}{ses-message-id} — rather
  // than reading a key off the event, since this event shape carries no S3
  // key at all (see the SesReceiptEvent comment above).
  const key = `${inboxPrefix(normalizedAddress)}${messageId}`;

  const getResult = await s3.send(
    new GetObjectCommand({ Bucket: MAIL_BUCKET_NAME, Key: key }),
  );
  if (!getResult.Body) {
    return;
  }
  const rawOriginalBytes = await getResult.Body.transformToByteArray();

  const original = await PostalMime.parse(rawOriginalBytes);

  const { raw } = buildForwardMessage(
    { subject: original.subject ?? null },
    rawOriginalBytes,
    normalizedAddress,
    forwardToAddress,
  );

  await ses.send(
    new SendRawEmailCommand({
      // Source must be set explicitly here (not inferred from the raw
      // message's From: header) for the ses:FromAddress IAM condition on
      // this Lambda's role to evaluate deterministically — same reasoning
      // reply/index.ts documents for its own Source-setting.
      Source: normalizedAddress,
      RawMessage: { Data: raw },
    }),
  );
}
