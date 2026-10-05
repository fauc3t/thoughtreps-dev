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
| `ThoughtReps-prod-Landing` | Pending | S3 bucket (OAC) + CloudFront for the apex, `www` -> apex 301, `404.html`; ACM cert |
| `ThoughtReps-prod-Mail` | Pending | SES identity, MX, DMARC, mail bucket, receipt rule, ForwardFn, Cognito, HTTP API (ReplyFn/DeleteFn), mail web UI hosting |

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

| Item | Value |
| --- | --- |
| Cognito user pool id (`UserPoolId`) | _pending_ |
| Cognito client id (`UserPoolClientId`) | _pending_ |
| Cognito identity pool id (`IdentityPoolId`) | _pending_ |
| Mail bucket (`MailBucketName`) | _pending_ |
| API URL (`ApiUrl`) | _pending_ |
| Mail web bucket / distribution (`MailWebBucketName`, `MailWebDistributionId`) | _pending_ |
| Mail web URL (`MailWebUrl`) | _pending_ (expected https://mail.thoughtreps.com) |
| Landing bucket / distribution (`LandingBucketName`, `LandingDistributionId`) | _pending_ |
| Landing URL (`LandingUrl`) | _pending_ (expected https://thoughtreps.com) |
| Cognito web user created | _pending_ |
