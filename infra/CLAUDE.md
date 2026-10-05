# infra/

CDK app (`bin/thoughtreps.ts`, wired through `lib/app-stage.ts`) for the landing site and mail at thoughtreps.com, plus `mail-web/` (inbox UI, Vite + React). Mail is a replica of the separate `~/dev/simple-mail` project. Account, stack status and outputs live in `../INTEGRATIONS.md`; update it after every deploy. Deploy steps are in `../DEVELOPMENT.md`.

## Shared-account rules

The AWS account (`041459489812`) is shared with strands prod.

- Every stack is `ThoughtReps-prod-*`. Never modify, import from, or tear down `Strands-*`, `SimpleMail-*`, `DnsStack`, `ShortLinkDnsStack` or `CDKToolkit`.
- **Never create or activate an SES receipt rule set.** SES has one active set per region; ours is `simple-mail-prod`, owned by strands' `SimpleMail-prod-Mail`. `MailStack` adds its rule to that set by name (`sharedReceiptRuleSetName` in `lib/env-config.ts`). No `AwsCustomResource` for `SetActiveReceiptRuleSet`.
- Don't change the `Zone` construct id in `lib/dns-stack.ts`: a new id replaces the hosted zone, and the registrar's nameservers point at the current one. The zone and the mail bucket are `RETAIN`.
- Deploy with `--profile thoughtreps-dev`. Use `"prod/*"`, not `--all` (doesn't reach Stage-nested stacks).

## Mail constraints (carried over from simple-mail)

- **Inbound MX is a hand-written `route53.MxRecord`** to `inbound-smtp.us-east-1.amazonaws.com`; `ses.EmailIdentity` only writes DKIM/verification (and MAIL FROM) records.
- **us-east-1 only.** SES receiving needs an allow-listed region, and CloudFront certs must be issued in us-east-1.
- **`ses:SendRawEmail` can't be scoped by resource; `s3:DeleteObject` can.** ReplyFn is `resources: ['*']` with a `ses:FromAddress` `StringEquals` condition on the configured mailboxes; DeleteFn is scoped per address to `arnForObjects(inboxPrefix(address) + '*')`. See `lib/mail/api.ts`.
- **No `bucket.grantRead()` for narrow Lambdas.** It also grants `s3:GetBucket*`/`s3:List*` on the whole bucket. ForwardFn uses a hand-rolled `s3:GetObject` statement per forwarded inbox prefix (`lib/mail/mail-stack.ts`).
- **The mail bucket is versioned.** DeleteFn's safety net: deletes become recoverable delete markers.
- **`sanitizeHeaderValue` (`lambda/mail/shared/mimeHeaders.ts`) is the header-injection boundary.** Every value copied from a received message into an outbound reply/forward header must pass through it; it strips control characters (RFC 2047 decoding can yield embedded CRLF). Don't weaken it; RFC 2047 encoding is not a substitute.
- **ForwardFn is a second action on the receipt rule** (after the S3 action), not an S3 event notification: SES's S3 action doesn't reliably trigger `ObjectCreated` events.
- **Identity Pool federation uses the ID token**, not the access token (`mail-web/src/lib/credentials.ts`). Reads go browser -> S3 with federated credentials; only reply and delete go through the API.
- **`inboxPrefix` has one source: `lib/mail/inbox.ts`.** The receipt rule, Lambdas and mail-web all import it; never hardcode `/inbox/`.
- **DMARC stays `p=none`** until aggregate reports (to `alertEmail`) show clean delivery.
- **CfnOutputs live on `MailStack` / `LandingStack` themselves**, and `../scripts/deploy-*.sh` read the exact keys (`MailWebBucketName`, `UserPoolId`, ...). Don't rename or move them without updating the scripts.
- Adding a mailbox: edit `mailboxAddresses`/`forwardTo` in `lib/env-config.ts`, redeploy Mail, rerun `deploy-mail-web.sh`.
- Flat Identity Pool role with read access to the whole mail bucket is deliberate (single tenant).

## Deliverability

Passing SPF/DKIM/DMARC doesn't mean the inbox: a new sending domain has no reputation, so replies can land in spam for days to weeks. Don't re-check DNS because of a spam-foldered message unless `aws sesv2 get-email-identity` or `dig TXT` shows a real failure. `SendRawEmail` overwrites `Message-ID` and `Date`, so don't generate them.
