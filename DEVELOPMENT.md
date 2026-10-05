# Development

## First-time setup

Requires macOS with Xcode 16 or later (iOS 18+ deployment target) and a paid Apple Developer account signed in to Xcode (Xcode > Settings > Accounts).

```sh
cd ~/dev/thoughtreps-dev
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM
xcodegen && open ThoughtReps.xcodeproj
```

- `Config/Local.xcconfig` is gitignored. Set `DEVELOPMENT_TEAM` to your Team ID, which is listed under your team in Xcode > Settings > Accounts.
- If Xcode says the bundle ID is unavailable, also set `TR_BUNDLE_ID` there to something unique, such as `com.yourname.thoughtreps`.
- On a device, your team needs the App Group `group.<bundle id>` for the share extension (App ID `<bundle id>.share`). Automatic signing usually registers both; if not, add the group under Signing & Capabilities or at developer.apple.com. Simulator builds work without a team.
- The main app has the App Attest entitlement (`appattest-environment: production`, needed for Send Feedback). If device signing complains, enable the App Attest capability on the App ID at developer.apple.com. The simulator can't send feedback or export links, and both need the Share stack deployed.
- A free Apple ID also works, with 7-day installs and no iCloud.

## Everyday commands

| Task | Command |
| --- | --- |
| Regenerate the Xcode project (after pulling, or adding or removing files) | `xcodegen` |
| Run the app | ⌘R in Xcode |
| Run the tests in Xcode | ⌘U |
| Run the tests from the terminal | `xcodebuild test -scheme ThoughtReps -destination 'platform=iOS Simulator,name=<simulator>'` (names from `xcrun simctl list devices available`) |

`ThoughtReps.xcodeproj` is generated from `project.yml` and gitignored, so edit `project.yml` rather than the project's build settings.

The share extension (`ThoughtRepsShare`) hands thoughts to the app through an `Inbox/` folder in the App Group; `InboxImporter` imports it at launch and on foreground. Info.plists and entitlements are generated from `project.yml` and gitignored, so run `xcodegen` before building a fresh clone. After the first install, "Thought Reps" may not appear in the share sheet until the app has been launched once, or enabled under the share sheet's More / Edit Actions. The extension's `NSExtensionActivationRule` is a predicate string in `project.yml` (text, one `.md`/`.txt` file, or one web URL), so after changing it check a real share sheet: text selection, Safari page, `.md` file, photo, PDF.

Take Photo needs a real device; the simulator has no camera. Photo Library and Paste Image work in the simulator.

Debug builds seed sample thoughts on first launch. Settings > Developer can add more or delete everything.

To try the daily reminder, enable it in Settings and set the time a minute or two ahead, then background the app (the simulator shows banners too). Reminders are rescheduled on foreground and background, so they only reflect due thoughts as of the last time the app was active.

Debug builds also run `IntegrityChecker` over the whole store at launch and log any violations via `os.Logger` (subsystem `com.thoughtreps`). It never repairs or crashes, so a logged violation means a bug in a store write; fix the write rather than the data.

Search uses an FTS5 index at `Application Support/Search/search-index.sqlite` (derived data, excluded from backup). It is reconciled in the background at launch, and a missing or damaged file is rebuilt, so delete it to force a rebuild. Tests and previews use an in-memory index. Debug builds also run `SearchIndexChecker` at launch and log any mismatch with the store.

Before launch, a schema change means regenerating `ThoughtRepsTests/Fixtures/default.store`; the steps are in `ThoughtRepsTests/Fixtures/README.md` (`FixtureGenerator` runs only when `TEST_RUNNER_GENERATE_FIXTURE_TO` is set).

## Running on an iPhone

1. Connect the phone and turn on Developer Mode (Settings > Privacy & Security).
2. Pick the phone as the run destination in Xcode and press ⌘R.
3. The first time, trust the developer certificate under Settings > General > VPN & Device Management.

With a paid developer account the install lasts a year.

## Web and infrastructure

The landing site (`site-landing/`), the CDK app (`infra/`), the mail inbox UI (`infra/mail-web/`) and the export download page (`transfer-web/`) are a pnpm workspace (Node 24+, pnpm 11) separate from the iOS app. What's deployed is recorded in [INTEGRATIONS.md](INTEGRATIONS.md); infra rules are in `infra/CLAUDE.md`.

```sh
pnpm install
pnpm test && pnpm typecheck && pnpm lint && pnpm format:check   # repo root
cd infra && npx cdk synth -c env=prod
```

Local dev: `pnpm --filter @thoughtreps/site-landing dev` (likewise `@thoughtreps/transfer-web`; it needs no env, but a real link needs a deployed Share stack and a device-made export). For the mail UI, copy `infra/mail-web/.env.example` to `.env.local` and fill in the `VITE_*` values from the Mail stack outputs.

### Deploying (manual, no CI)

The AWS account is shared with strands prod, so only touch `ThoughtReps-prod-*` stacks. Use `--profile thoughtreps-dev`; cdk's "could not assume cdk-hnb659fds-*-role ... Proceeding anyway" warnings are harmless (the profile is the root user).

1. `cd infra && npx cdk deploy prod/DnsStack -c env=prod --profile thoughtreps-dev` (done 2026-10-05).
2. Set the zone's nameservers at the registrar (listed in INTEGRATIONS.md) and wait until `dig NS thoughtreps.com +short` shows them. ACM certs and SES verification need the delegation.
3. `npx cdk deploy "prod/*" -c env=prod --profile thoughtreps-dev`. Quote the pattern; `--all` doesn't reach Stage-nested stacks.
4. `scripts/deploy-landing.sh`, `scripts/deploy-mail-web.sh` and `scripts/deploy-transfer-web.sh` build, sync to S3 and invalidate CloudFront, reading the stack outputs (`AWS_PROFILE` defaults to `thoughtreps-dev`).
5. Create the Cognito user (self-signup is off), with `UserPoolId` from the Mail stack outputs:

   ```sh
   aws cognito-idp admin-create-user --user-pool-id <UserPoolId> --username you@example.com --user-attributes Name=email,Value=you@example.com Name=email_verified,Value=true --message-action SUPPRESS --profile thoughtreps-dev
   aws cognito-idp admin-set-user-password --user-pool-id <UserPoolId> --username you@example.com --password '<password>' --permanent --profile thoughtreps-dev
   ```

6. Send a test mail to hello@thoughtreps.com; confirm it lands in the mail bucket and forwards.

Then update INTEGRATIONS.md with the new status and output values.

To add a mailbox, edit `mailboxAddresses`/`forwardTo` in `infra/lib/env-config.ts`, redeploy Mail, and rerun `deploy-mail-web.sh` (it reads the `MailboxAddresses` output, so there is no separate `VITE_` edit).
