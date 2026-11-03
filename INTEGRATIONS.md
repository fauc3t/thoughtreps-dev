# Integrations

Where the web side of Thought Reps runs. Content-only deploys (`deploy-landing.sh`, `deploy-transfer-web.sh`, `deploy-mail-web.sh`) need no entry here; steps are in [DEVELOPMENT.md](DEVELOPMENT.md).

## AWS

Everything (DNS for `thoughtreps.com`, the landing site, mail and the mail UI at `mail.thoughtreps.com`, export links at `transfer.thoughtreps.com`, and the sync server) lives in `~/dev/thoughtreps-aws`. Its CDK pipeline deploys the `ThoughtReps-prod-*` stacks into the prod account `038635648573`, profile `thoughtreps-prod`. That repo's README holds the stack outputs, the mail and DNS setup and the record of the 2026-11-02 cutover. The deploy scripts here read their bucket and distribution ids from those stacks' outputs, so no ids are recorded in this file.

## Legacy shared account (041459489812)

Until 2026-11-02 this repo's `infra/` deployed the same four stacks (`ThoughtReps-prod-Dns`, `-Landing`, `-Mail`, `-Share`) into account `041459489812` (profile `thoughtreps-prod-legacy`, the root user). That account is shared with strands prod. After the cutover, the stacks, the legacy `thoughtreps.com` SES identity and hosted zone `Z06229403C4P8HR6DYOGE` were deleted. Strands' resources there (`Strands-*`, `SimpleMail-*`, the `simple-mail-prod` receipt rule set, `DnsStack`, `ShortLinkDnsStack`, `CDKToolkit`) were not touched.

The resources those stacks kept on delete (RETAIN) were deleted later the same day: the mail bucket with all its versions, Cognito user pool `us-east-1_syDehk89q`, both waitlist tables, the Lambda log groups and the IAM user `herald-ses-sender`. The one real waitlist sign-up was copied to the prod table first. No thoughtreps resources are left in this account.

## Outside AWS: herald

The daily social pipeline lives in its own repo, [`fauc3t/herald-ai`](https://github.com/fauc3t/herald-ai) (`~/dev/herald-ai`), configured for this app by `projects/thoughtreps.json`. It sent its digest through the legacy account's SES identity as the IAM user `herald-ses-sender`; both are deleted, and the local `herald` AWS profile now holds a dead key. **Herald is stopped as of 2026-11-02**: the launchd agent `ai.herald.daily` was booted out and disabled, and its plist is kept in `~/Library/LaunchAgents/`. Restarting it needs a sender in the prod account first, which hasn't been created.
