# infra/

CDK app (`bin/thoughtreps.ts`, wired through `lib/app-stage.ts`) for the landing site, mail and the one-time export link (`ThoughtReps-prod-Share`, `lib/export-link/`, `lambda/export-link/`) at thoughtreps.com, plus `mail-web/` (inbox UI, Vite + React). Mail is a replica of the separate `~/dev/simple-mail` project. Account, stack status and outputs live in `../INTEGRATIONS.md`; update it after every deploy. Deploy steps are in `../DEVELOPMENT.md`.

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

## Export link constraints

The device encrypts its export and uploads ciphertext; the key lives only in the link's `#` fragment. Deployed 2026-10-05 (`cdk deploy prod/ShareStack`); the feedback route was added afterward and is not yet deployed. A real-device attestation is still untested.

- **The export bucket is unversioned on purpose** (unlike the mail bucket): deletes must really remove the ciphertext. The 2-day lifecycle is only a backstop; link expiry is 24h from `complete`, enforced by `claim` and the 15-minute `SweepFn`.
- **IAM is scoped to `exports/*` with no `s3:ListBucket`**, so HEAD on a missing object returns 403; treat that as "not uploaded".
- **Revoked/expired links stay in the sparse `openIndex` until their object is actually deleted.** `complete` is idempotent for an owned, unexpired ready link.
- **The public status endpoint must have no side effects**, so link-preview bots can't burn a link. Only `claim` (ready -> used, atomic) hands out the 5-minute presigned GET; `done` deletes the object.
- **Devices are identified by App Attest keyId**, not `identifierForVendor`. Only production attestation is accepted (App ID `appAttestAppId` in `env-config.ts`). The iOS app needs the App Attest capability and `appattest-environment` = `production` for all builds.
- **Hash contracts the iOS client must match:** attestation `clientDataHash` = SHA256 of the UTF-8 bytes of the base64url challenge string; signed requests are an assertion over SHA256(raw body bytes) plus a single-use challenge.
- **`cbor.ts` is a hand-written bounded decoder** because cbor-x's native build script is blocked by pnpm 11. `Deps.attestationRootPem` is a test-only seam; the Apple root is pinned in `apple-root.ts`.
- Limits: 100 MB, 10 creates/day/device, one open link per install (a new one revokes the previous). Status codes: 400 bad_request, 401 auth, 404 not_found, 409 upload_mismatch, 410 used/expired/revoked, 413 too_large, 429 rate_limited.
- **Feedback (`POST /api/v1/feedback`, `FeedbackFn`) shares this API and App Attest auth** (`authenticateSigned`). Strict body, message 1..5000 UTF-16 units, required email (becomes Reply-To). Limit is 3/device/UTC day on its own counter (`RATE#feedback#<keyId>#<day>`); order is check count -> send -> increment, so a failed SES send doesn't spend a slot. Concurrent requests may briefly exceed 3 (accepted); a failed increment after a successful send still returns 200. SES failure is 500.
- **Never log the feedback message or email.** The mail body puts the diagnostics block *before* `-- Message --` so the message can't forge diagnostics, and the subject is fixed (`[Feature] Feedback` / `[Bug] Feedback`). IAM is DynamoDB Get/Update/Delete plus `ses:SendEmail` on `*` with a `ses:FromAddress` condition (`feedbackFromAddress`, sent to `feedbackToAddress`); no S3. Reply-To is only on the original attached inside ForwardFn's forward.
- Request/response schemas are in `lib/export-link/schemas.ts`, exported as `./export-link/schemas` for the download page; the iOS client mirrors these shapes in Swift, so keep them in sync.

## Deliverability

Passing SPF/DKIM/DMARC doesn't mean the inbox: a new sending domain has no reputation, so replies can land in spam for days to weeks. Don't re-check DNS because of a spam-foldered message unless `aws sesv2 get-email-identity` or `dig TXT` shows a real failure. `SendRawEmail` overwrites `Message-ID` and `Date`, so don't generate them.
