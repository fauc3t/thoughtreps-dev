# Integrations

What exists in AWS for the web side of Thought Reps, and where. **Update this after every deploy** (status, outputs, ids). Rules for changing it are in [`infra/CLAUDE.md`](infra/CLAUDE.md); deploy steps are in [DEVELOPMENT.md](DEVELOPMENT.md).

## AWS account

Account `041459489812`, region `us-east-1`, CLI profile `thoughtreps-dev` (signs in as the account root user, so cdk prints "could not assume cdk-hnb659fds-*-role ... Proceeding anyway"; harmless). Deploys are manual `cdk deploy`; there is no pipeline.

> **This account is shared with strands prod (cross-account).** It also hosts `Strands-prod-*`, `SimpleMail-prod-*` (strands.io mail), `DnsStack`, `ShortLinkDnsStack`, and the shared `CDKToolkit` bootstrap stack. Our stacks are all prefixed `ThoughtReps-prod-`; never modify the others.

## Stacks

All in one `cdk.Stage` named `prod` (`infra/lib/app-stage.ts`).

| Stack | Status | Owns |
| --- | --- | --- |
| `ThoughtReps-prod-Dns` | Deployed 2026-10-05 | Route53 hosted zone `thoughtreps.com` (RETAIN) |
| `ThoughtReps-prod-Landing` | Deployed 2026-10-05 | S3 bucket (OAC) + CloudFront for the apex, `www` -> apex 301 and `/x` -> `/x/index.html` rewrite (viewer-request function), `404.html`; ACM cert |
| `ThoughtReps-prod-Mail` | Deployed 2026-10-05 | SES identity, MX, DMARC, mail bucket, receipt rule, ForwardFn, Cognito, HTTP API (ReplyFn/DeleteFn), mail web UI hosting |
| `ThoughtReps-prod-Share` | Deployed 2026-10-05 (FeedbackFn added, placeholder `BucketDeployment` removed the same day) | Export-link backend: unversioned export bucket, DynamoDB link table, App Attest device/export-link/public/sweep Lambdas, FeedbackFn (`POST /feedback`, SES send), HTTP API, `transfer.thoughtreps.com` site (download page from `transfer-web/`, deployed by `scripts/deploy-transfer-web.sh`) |

### DNS

- Hosted zone `thoughtreps.com`, id `Z06229403C4P8HR6DYOGE`.
- Nameservers: `ns-502.awsdns-62.com`, `ns-698.awsdns-23.net`, `ns-1437.awsdns-51.org`, `ns-1574.awsdns-04.co.uk`.
- The domain is registered outside AWS; these nameservers are set at the registrar by hand. Check with `dig NS thoughtreps.com +short`. Delegation must be live before Landing/Mail deploy (ACM and SES verification need it).

### Mail (`hello@thoughtreps.com`)

- SES domain identity `thoughtreps.com`, MAIL FROM `bounce.thoughtreps.com`, inbound MX, `_dmarc` at `p=none` with reports to `me@nickhorn.com`.
- **The receipt rule lives in strands' rule set.** SES allows one active receipt rule set per region, and `simple-mail-prod` is the active one. It is owned by the `SimpleMail-prod-Mail` stack in the separate `~/dev/simple-mail` repo (it also carries hello@/developer@/social@strands.io). Our Mail stack adds its rule to that set by name and never creates or activates a rule set. **Tearing down `SimpleMail-prod-Mail` removes our rule too.** This is deliberately documented only here.
- Mail lands in the versioned, RETAIN mail bucket under `hello@thoughtreps.com/inbox/`; `ForwardFn` also forwards it to `me@nickhorn.com`.
- SES production access is account-wide and already on; the CDK bootstrap is shared too.
- Inbox UI: `mail.thoughtreps.com` (Cognito sign-in, no self-signup).

## Values filled in after deploy

Last deploy: 2026-10-05 (Dns, Landing and Mail, plus `deploy-landing.sh` and `deploy-mail-web.sh`; Share redeployed the same day with the feedback route, and an unsigned `POST /api/v1/feedback` returns 400 `bad_request` as expected; Share redeployed again to drop the placeholder, then `deploy-transfer-web.sh`: `/x/<id>` serves "Your Thought Reps export" and an unknown id's status returns 404 `not_found`). Landing redeployed 2026-10-05 (`cdk deploy prod/LandingStack --exclusively`, function code only) for the directory-index rewrite, then `deploy-landing.sh` with the help center: `/help`, `/help/<slug>`, `/sitemap.xml` and `/robots.txt` return 200, an unknown slug 404, and `www.thoughtreps.com/help` 301s to the apex. `deploy-landing.sh` again the same day for the visual help pass (icons, mockups, rewrite); `/third-party-licenses.txt` returns 200. SES identity `thoughtreps.com` verified (DKIM and MAIL FROM `SUCCESS`); MX resolves to `inbound-smtp.us-east-1.amazonaws.com`; our rule sits first in `simple-mail-prod`, ahead of the three strands.io rules, which are unchanged.

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
| Export API URL (`ExportApiUrl`) | https://transfer.thoughtreps.com/api/v1 |
| Transfer site bucket / distribution (`TransferSiteBucketName`, `TransferDistributionId`) | `thoughtreps-prod-share-transfersitebucket6a3fef50-bl0j1eymkxco` / `E622TVJW5S9HN` |
| Transfer URL (`TransferUrl`) | https://transfer.thoughtreps.com |
| Export link real-device App Attest test | _pending_ (iOS `AppAttestClient` exists; needs the deploy and a device build; first check is Settings > Send Feedback) |
