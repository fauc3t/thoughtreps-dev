# Integrations

What exists in AWS for the web side of Thought Reps, and where. **Update this when a deploy changes a stack's status, outputs or ids**; content-only deploys (`deploy-landing.sh`, `deploy-transfer-web.sh`, `deploy-mail-web.sh`) need no entry. There's no deploy log; git history covers that. Rules for changing it are in [`infra/CLAUDE.md`](infra/CLAUDE.md); deploy steps are in [DEVELOPMENT.md](DEVELOPMENT.md).

## AWS account

Account `041459489812`, region `us-east-1`, CLI profile `thoughtreps-dev` (signs in as the account root user, so cdk prints "could not assume cdk-hnb659fds-*-role ... Proceeding anyway"; harmless). Deploys are manual `cdk deploy`; there is no pipeline.

> **This account is shared with strands prod (cross-account).** It also hosts `Strands-prod-*`, `SimpleMail-prod-*` (strands.io mail), `DnsStack`, `ShortLinkDnsStack`, and the shared `CDKToolkit` bootstrap stack. Our stacks are all prefixed `ThoughtReps-prod-`; never modify the others.

## Stacks

All in one `cdk.Stage` named `prod` (`infra/lib/app-stage.ts`).

| Stack | Status | Owns |
| --- | --- | --- |
| `ThoughtReps-prod-Dns` | Deployed 2026-10-05 | Route53 hosted zone `thoughtreps.com` (RETAIN) |
| `ThoughtReps-prod-Landing` | Deployed 2026-10-05; security headers + CSP 2026-10-07 | S3 bucket (OAC) + CloudFront for the apex, `www` -> apex 301 and `/x` -> `/x/index.html` rewrite (viewer-request function), `404.html`; ACM cert |
| `ThoughtReps-prod-Mail` | Deployed 2026-10-05; reply attachments added 2026-10-06; security headers + CSP 2026-10-07; social@, repsbot@ and nickhorn@ mailboxes 2026-10-09 | SES identity, MX, DMARC, mail bucket, receipt rules (one per mailbox), ForwardFn, Cognito, HTTP API (ReplyFn/DeleteFn/AttachmentUrlFn), attachment upload bucket (unversioned, 1-day expiry), mail web UI hosting |
| `ThoughtReps-prod-Share` | Deployed 2026-10-05; waitlist added 2026-10-07; custom security headers + CSP 2026-10-07 | Export-link backend: unversioned export bucket, DynamoDB link table, App Attest device/export-link/public/sweep Lambdas, FeedbackFn (`POST /feedback`, SES send), WaitlistFn (`POST /waitlist`, public, CORS for thoughtreps.com only), `WaitlistTable` (RETAIN, PITR), HTTP API, `transfer.thoughtreps.com` site (download page from `transfer-web/`, deployed by `scripts/deploy-transfer-web.sh`) |

### DNS

- Hosted zone `thoughtreps.com`, id `Z06229403C4P8HR6DYOGE`.
- Nameservers: `ns-502.awsdns-62.com`, `ns-698.awsdns-23.net`, `ns-1437.awsdns-51.org`, `ns-1574.awsdns-04.co.uk`.
- The domain is registered outside AWS; these nameservers are set at the registrar by hand. Check with `dig NS thoughtreps.com +short`. Delegation must be live before Landing/Mail deploy (ACM and SES verification need it).

### Mail (`hello@`, `social@`, `repsbot@`, `nickhorn@thoughtreps.com`)

- SES domain identity `thoughtreps.com`, MAIL FROM `bounce.thoughtreps.com`, inbound MX, `_dmarc` at `p=none` with reports to `me@nickhorn.com`.
- **The receipt rule lives in strands' rule set.** SES allows one active receipt rule set per region, and `simple-mail-prod` is the active one. It is owned by the `SimpleMail-prod-Mail` stack in the separate `~/dev/simple-mail` repo (it also carries hello@/developer@/social@strands.io). Our Mail stack adds one rule per mailbox to that set by name and never creates or activates a rule set. **Tearing down `SimpleMail-prod-Mail` removes our rules too.** This is deliberately documented only here.
- Mail lands in the versioned, RETAIN mail bucket under `<address>/inbox/` (e.g. `hello@thoughtreps.com/inbox/`); `ForwardFn` also forwards every mailbox to `me@nickhorn.com`.
- SES production access is account-wide and already on; the CDK bootstrap is shared too.
- Inbox UI: `mail.thoughtreps.com` (Cognito sign-in, no self-signup).

### Outside CDK: herald (social content + Reddit backlog)

The daily social pipeline lives in its own repo, [`fauc3t/herald-ai`](https://github.com/fauc3t/herald-ai) (`~/dev/herald-ai`), configured for this app by `projects/thoughtreps.json` there. It is not part of `infra/` and no stack owns it. It touches this account only by:

- **Sending the daily digest** from `social@thoughtreps.com` to `me@nickhorn.com` through our SES identity. It runs unattended, so it uses an IAM user with its own keys instead of the expiring `thoughtreps-dev` login: `herald-ses-sender`, whose policy allows `ses:SendEmail`/`SendRawEmail` only on the `thoughtreps.com` domain identity (in the region given), only with `ses:FromAddress` equal to `social@thoughtreps.com` and `ses:Recipients` (`ForAllValues:StringEquals`) limited to `me@nickhorn.com`, plus `ses:GetAccount`. It's created by `scripts/create-ses-sender.sh thoughtreps-dev social@thoughtreps.com me@nickhorn.com us-east-1 herald` in that repo (args: `<admin-profile> <from-address> <to-address> <region> [profile-name]`) and saved as the local AWS profile `herald`. The script re-applies the policy on every run; if the user already has access keys but the profile doesn't, it lists them and stops. Status: created 2026-10-10. Remove it with `aws iam delete-access-key`, `delete-user-policy` and `delete-user`.
- **Reading the public site**: `thoughtreps.com/sitemap.xml` plus the `/blog/` and `/help/` pages, as source material.

It runs as a launchd agent on the Mac (`ai.herald.daily`, daily plus at login). Its output goes to iCloud Drive/Herald, not AWS. Social accounts it lists all sign in with `social@thoughtreps.com`.

## Values filled in after deploy

SES identity `thoughtreps.com` verified (DKIM and MAIL FROM `SUCCESS`); MX resolves to `inbound-smtp.us-east-1.amazonaws.com`; our rule sits first in `simple-mail-prod`, ahead of the three strands.io rules, which are unchanged.

| Item | Value |
| --- | --- |
| Cognito user pool id (`UserPoolId`) | `us-east-1_syDehk89q` |
| Cognito client id (`UserPoolClientId`) | `2ujo7ef2dpmhim8g5uq7kdg4bj` |
| Cognito identity pool id (`IdentityPoolId`) | `us-east-1:09026af8-7da2-4c4d-9df1-df5780262905` |
| Mail bucket (`MailBucketName`) | `thoughtreps-prod-mail-mailbucketfabec941-faprsykfvfyq` |
| API URL (`ApiUrl`) | https://q3ihbwdjgj.execute-api.us-east-1.amazonaws.com |
| Mail web bucket / distribution (`MailWebBucketName`, `MailWebDistributionId`) | `thoughtreps-prod-mail-websitebucket1e6f6f45-wkfffubeisgp` / `E8O3L2H8SSBPT` |
| Mail web URL (`MailWebUrl`) | https://mail.thoughtreps.com |
| Landing bucket / distribution (`LandingBucketName`, `LandingDistributionId`) | `thoughtreps-prod-landing-landingbucket23fe90fb-nzgzwymbfpxa` / `ELBMIPHTLCIZ0` |
| Landing URL (`LandingUrl`) | https://thoughtreps.com |
| Cognito web user created | _pending_ |
| Export bucket / link table (`ExportBucketName`, `ExportLinkTableName`) | `thoughtreps-prod-share-exportbucket4e99310e-wjwcqoidssqh` / `ThoughtReps-prod-Share-ExportLinkTableF59C9DFC-7H2NOAU9YLWG` |
| Waitlist table (`WaitlistTableName`) | `ThoughtReps-prod-Share-WaitlistTable9B05A3AC-1IUQYLIYAVGYL` |
| Export API URL (`ExportApiUrl`) | https://transfer.thoughtreps.com/api/v1 |
| Transfer site bucket / distribution (`TransferSiteBucketName`, `TransferDistributionId`) | `thoughtreps-prod-share-transfersitebucket6a3fef50-bl0j1eymkxco` / `E622TVJW5S9HN` |
| Transfer URL (`TransferUrl`) | https://transfer.thoughtreps.com |
| Waitlist rollout | Done 2026-10-07: Share stack deployed, then `scripts/deploy-landing.sh` |
| Response headers rollout | Done 2026-10-07: Landing, Mail and Share stacks deployed (each distribution has its own `ResponseHeadersPolicy`: HSTS 2y incl. subdomains, nosniff, frame DENY, referrer policy, CSP), then all three content scripts; headers checked live with `curl -I` |
| Export link real-device App Attest test | Passed 2026-10-06: link created on a device, and tapping it opens the app (Universal Link) |
| Feedback real-device App Attest test | Passed 2026-10-06: sent from Settings > Send Feedback on a device |
