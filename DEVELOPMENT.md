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
- Importing from an export link needs a real device (App Attest) and the Universal Links entitlement `applinks:transfer.thoughtreps.com`; tapping a link only opens the app once the AASA file is deployed. Check with `curl -sI https://transfer.thoughtreps.com/.well-known/apple-app-site-association` (expect 200, `application/json`, no redirect). iOS caches it, so reinstall the app after changing it. Pasting a link in Settings > Import works without it.
- A free Apple ID also works, with 7-day installs and no iCloud.

## Everyday commands

| Task | Command |
| --- | --- |
| Regenerate the Xcode project (after pulling, or adding or removing files) | `xcodegen` |
| Run the app | ⌘R in Xcode |
| Run the tests in Xcode | ⌘U |
| Run the tests from the terminal | `xcodebuild test -scheme ThoughtReps -destination 'platform=iOS Simulator,name=<simulator>'` (names from `xcrun simctl list devices available`); also run it on an iPad simulator, e.g. `iPad Pro 13-inch (M5)` |
| Run the keyboard and iPad split view UI tests | `xcodebuild test -scheme ThoughtRepsScreenshots -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' -only-testing:ThoughtRepsUITests/KeyboardAndSplitViewTests` (the editor's ⌘↩ and Esc need a device check) |

`ThoughtReps.xcodeproj` is generated from `project.yml` and gitignored, so edit `project.yml` rather than the project's build settings.

The share extension (`ThoughtRepsShare`) hands thoughts to the app through an `Inbox/` folder in the App Group; `InboxImporter` imports it at launch and on foreground. Info.plists and entitlements are generated from `project.yml` and gitignored, so run `xcodegen` before building a fresh clone. After the first install, "Thought Reps" may not appear in the share sheet until the app has been launched once, or enabled under the share sheet's More / Edit Actions. The extension's `NSExtensionActivationRule` is a predicate string in `project.yml` (text, one web URL, or one file or photo of any type), so after changing it check a real share sheet: text selection, Safari page, `.md` file, photo, PDF, and a file over 5 MB (refused in the share UI). A shared photo or file is copied into the inbox as `<id>.attachment` beside its `.json`; the app turns a photo into a gallery block and any other file into a file block.

Take Photo needs a real device; the simulator has no camera. Photo Library and Paste Image work in the simulator.

Debug builds seed sample thoughts on first launch. Settings > Developer can add more or delete everything.

To try the daily reminder, enable it in Settings and set the time a minute or two ahead, then background the app (the simulator shows banners too). Reminders are rescheduled on foreground and background, so they only reflect due thoughts as of the last time the app was active.

Debug builds also run `IntegrityChecker` over the whole store at launch and log any violations via `os.Logger` (subsystem `com.thoughtreps`). It never repairs or crashes, so a logged violation means a bug in a store write; fix the write rather than the data.

Search uses an FTS5 index at `Application Support/Search/search-index.sqlite` (derived data, excluded from backup). It is reconciled in the background at launch, and a missing or damaged file is rebuilt, so delete it to force a rebuild. Tests and previews use an in-memory index. Debug builds also run `SearchIndexChecker` at launch and log any mismatch with the store.

Before launch, a schema change means regenerating `ThoughtRepsTests/Fixtures/default.store`; the steps are in `ThoughtRepsTests/Fixtures/README.md` (`FixtureGenerator` runs only when `TEST_RUNNER_GENERATE_FIXTURE_TO` is set).

Debug builds also have a screenshot mode for the App Store screenshots: launch with `-screenshotMode` (`ScreenshotMode.swift`) for an in-memory store with a fixed marketing seed, light mode and no prompts. It is driven by the `ThoughtRepsScreenshots` scheme and `app-store-assets/Screenshots/gen.mjs --capture` (`--capture-ipad` for iPad raws); see that folder's README.

## Running on an iPhone

1. Connect the phone and turn on Developer Mode (Settings > Privacy & Security).
2. Pick the phone as the run destination in Xcode and press ⌘R.
3. The first time, trust the developer certificate under Settings > General > VPN & Device Management.

With a paid developer account the install lasts a year.

## Sync against the local server

The sync server lives in `thoughtreps-aws`. Its local runner serves the API on DynamoDB Local (needs Java, no Docker; the store is in memory and lost on exit):

```sh
cd <thoughtreps-aws>
SYNC_LOCAL_SECRET=dev-secret pnpm --filter infra sync:local   # http://127.0.0.1:8787/api/v1 (SYNC_LOCAL_PORT to change)
```

**Contract and engine tests.** The suite always runs the fake-server half. To run the HTTP half too, pass the server through `TEST_RUNNER_`-prefixed variables (without them those suites show as skipped):

```sh
TEST_RUNNER_THOUGHTREPS_SYNC_TEST_URL=http://127.0.0.1:8787/api/v1 \
TEST_RUNNER_THOUGHTREPS_SYNC_TEST_SECRET=dev-secret \
xcodebuild test -scheme ThoughtReps -destination 'platform=iOS Simulator,name=<simulator>'
```

Each test makes its own vault with a random id. The blob cases (upload, present, download round trip, missing, pointer pushes and `blob_missing`) go through the runner's stand-in presigned URLs at `<origin>/_blobs/<ticket>`, which enforce the same length and checksum rules as S3.

**Two simulators.** A DEBUG build starts syncing when all four launch variables are set (any missing and it only fills the outbox):

- `THOUGHTREPS_SYNC_URL`: `http://127.0.0.1:8787/api/v1`
- `THOUGHTREPS_SYNC_VAULT`: any id of letters, digits, `_` or `-`; the vault is created on first launch
- `THOUGHTREPS_SYNC_DEV_SECRET`: the runner's secret
- `THOUGHTREPS_SYNC_KEY`: base64 of 32 bytes, the same on both devices. Make one with `openssl rand -base64 32`.

From the command line prefix each with `SIMCTL_CHILD_` (`SIMCTL_CHILD_THOUGHTREPS_SYNC_URL=... xcrun simctl launch <device> com.thoughtreps.app`); from Xcode set them unprefixed under the scheme's Run > Arguments > Environment Variables.

The runner's store is in memory, so restarting it gives every vault a new epoch and an old install stops with "epoch changed". Delete and reinstall the app on both simulators after a restart.

**Sync lab.** In a DEBUG build, Settings > Developer > Sync lab shows the debug sync target (server and vault, never the secret or key), the engine's phase and attention state (stopped, epoch changed, server refused, update required), the outbox, held and parked counts, the last successful sync and the server clock offset. "Sync now" runs a cycle; "Run checks" runs `IntegrityChecker` and `SearchIndexChecker` and shows pass or fail with the violation count. An "Account" section signs in on a real iPhone (App Attest and Sign in with Apple don't work in the simulator; the App ID needs the Sign in with Apple capability enabled): "Sign in with Apple and create vault" registers sync's App Attest key, creates the account and vault on the dev API (`THOUGHTREPS_SYNC_URL` overrides), and stores the vault key in the Keychain, after which the engine starts on a bearer session at launch unless `THOUGHTREPS_SYNC_VAULT` is set. "Sign out and forget key" removes the key from the device only. "Save sync key to iCloud Keychain" (on by default) keeps a second, synchronizable copy; "Delete iCloud copy" removes it.

To pair a second device (real devices only: App Attest and the camera), tap "Add a device" on the first to show a QR invite (valid 10 minutes), then scan it from the Sync lab on the other. A device on the same Apple ID can join from the iCloud copy instead, or with the recovery code shown on the first. Joining asks to confirm first; if the device already has thoughts it then asks to merge or erase (erase needs a second confirm and runs only after the join succeeds). A "Devices" section lists the vault's devices (names are opened on device, "Unnamed device" if missing; added and last seen; "This device"; "N of <limit> devices"); rename only your own, remove another with a confirm. "Erase this device and leave sync" removes this device on the server first, then stops the engine and clears the key and sync state (the iCloud copy stays), then erases thoughts after a second confirm (skipped with none). "Delete sync data" deletes the account and vault on the server (it asks for Sign in with Apple only if the server wants a fresh sign-in), clears this device and the iCloud copy, and leaves every device's thoughts alone. If a Keychain key exists with no matching sync history (after a reinstall), sync doesn't start on its own: the Sync lab asks "Resume syncing with this vault?" (Resume or Forget). Scripted scenarios on real devices and fault switches are still to come.

**Two-simulator integration run.** `scripts/sync-integ.sh` runs the scenarios in `ThoughtRepsUITests/SyncScenarioTests.swift` against the local server on two simulators at once (an iPhone, "TR Sync A", that asserts what the user sees, and an iPad, "TR Sync B", that does the other side's work). It needs Xcode, Java, pnpm and a `thoughtreps-aws` checkout with `pnpm install --frozen-lockfile` done (default `../thoughtreps-aws`, or set `THOUGHTREPS_AWS_DIR`; the script never modifies it):

```sh
scripts/sync-integ.sh                                  # every scenario, prints PASS or FAIL per scenario, exits non-zero on failure
scripts/sync-integ.sh testDeletedWhileOpen_editor      # one scenario
```

It starts the local server itself (or reuses one already answering on the port) and stops what it started, creates the two simulators if missing (`xcrun simctl create`; it never touches or shuts down others), builds once with its own derived data (`ThoughtRepsSyncIntegration` scheme), and gives each scenario a fresh vault and key. The first line printed is the run directory with each scenario's logs and `.xcresult` bundles. The two test runners coordinate through marker files in a host temp directory, and a device syncs by backgrounding and foregrounding the app. To add a scenario, add a test method to `SyncScenarioTests` and its name to `SCENARIOS` in the script. Don't run it at the same time as another run: it uses the fixed simulator names and the same port (8787, or `SYNC_LOCAL_PORT`).

## Releasing to the App Store

Before uploading a build to App Store Connect (TestFlight or release), check every item. The privacy items must match each other, so change them together (see the privacy rule in CLAUDE.md).

1. **Privacy manifests are current.** `ThoughtReps/Resources/PrivacyInfo.xcprivacy` and `ThoughtRepsShare/PrivacyInfo.xcprivacy` declare every required-reason API in use and every data type collected. After archiving, open Xcode's Organizer, right-click the archive and choose Generate Privacy Report to confirm the merged result (it includes ZIPFoundation's own manifest).
2. **App Store Connect privacy answers match the manifest.** Under App Privacy: email address, customer support, other diagnostic data and device ID, each used for App Functionality, linked to the user, not used for tracking. Nothing else is collected; the export-link file is encrypted on device and not declared.
3. **Export compliance is answered.** The app uses only standard encryption (HTTPS and CryptoKit AES-GCM for export links), which qualifies for the exemption. `ITSAppUsesNonExemptEncryption: false` is set under the app target's `info:` in `project.yml`, so uploads don't ask. Revisit if any non-standard encryption is added.
4. **URLs are live.** Privacy policy `https://thoughtreps.com/privacy` and support `https://thoughtreps.com/support`, and the policy's "Last updated" date reflects any data change since the last release.
5. **Age rating** is 4+, consistent with the policy's under-13 line.

### Installing on your own devices

`scripts/install-devices.sh` builds Debug once and installs it on every paired iPhone and iPad this Mac can reach, over USB or Wi-Fi, in about a minute with no Apple processing. To target specific devices, pass their UDIDs (`scripts/install-devices.sh <UDID> ...`); `scripts/install-devices.sh --list` shows each paired device's UDID. Pair each device over Wi-Fi once: plug it in, then Xcode > Window > Devices and Simulators > "Connect via network". Devices must be awake and on the Mac's network; a locked device gets the install but the app isn't launched. Use TestFlight for other testers or when away from the Mac.

### Uploading to TestFlight

1. Once: create the app record in App Store Connect for the bundle ID in `TR_BUNDLE_ID` (`Config/Local.xcconfig`).
2. Commit your changes, then run `scripts/testflight.sh`. It refuses to run with uncommitted tracked changes, archives a Release build with a UTC-timestamp build number (`MARKETING_VERSION` comes from `project.yml`), and uploads it. It uses the Apple account signed into Xcode; to use an API key instead, set `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID`.
3. The build appears in TestFlight after Apple's processing (usually 10-30 minutes). Internal testers need no review. Builds expire after 90 days.
4. TestFlight builds are Release, so DEBUG-only checks (`IntegrityChecker`) don't run. Use Xcode installs for debugging.

## Web and infrastructure

The landing site (`site-landing/`), the CDK app (`infra/`), the mail inbox UI (`infra/mail-web/`) and the export download page (`transfer-web/`) are a pnpm workspace (Node 24+, pnpm 11) separate from the iOS app. What's deployed is recorded in [INTEGRATIONS.md](INTEGRATIONS.md); infra rules are in `infra/CLAUDE.md`.

```sh
pnpm install
pnpm test && pnpm typecheck && pnpm lint && pnpm format:check   # repo root
cd infra && npx cdk synth -c env=prod
```

Local dev: `pnpm --filter @thoughtreps/site-landing dev` (likewise `@thoughtreps/transfer-web`; `/help` only exists in the built output, since dev has no client router: preview with `pnpm --filter @thoughtreps/site-landing build` and a static server on `dist/`; it needs no env, but a real link needs a deployed Share stack and a device-made export). For the mail UI, copy `infra/mail-web/.env.example` to `.env.local` and fill in the `VITE_*` values from the Mail stack outputs.

### Deploying (manual, no CI)

The AWS account is shared with strands prod, so only touch `ThoughtReps-prod-*` stacks. Use `--profile thoughtreps-prod-legacy`; cdk's "could not assume cdk-hnb659fds-*-role ... Proceeding anyway" warnings are harmless (the profile is the root user).

1. `cd infra && npx cdk deploy prod/DnsStack -c env=prod --profile thoughtreps-prod-legacy` (done 2026-10-05).
2. Set the zone's nameservers at the registrar (listed in INTEGRATIONS.md) and wait until `dig NS thoughtreps.com +short` shows them. ACM certs and SES verification need the delegation.
3. `npx cdk deploy "prod/*" -c env=prod --profile thoughtreps-prod-legacy`. Quote the pattern; `--all` doesn't reach Stage-nested stacks.
4. `scripts/deploy-landing.sh`, `scripts/deploy-mail-web.sh` and `scripts/deploy-transfer-web.sh` build, sync to S3 and invalidate CloudFront, reading the stack outputs (`AWS_PROFILE` defaults to `thoughtreps-prod-legacy`).
5. Create the Cognito user (self-signup is off), with `UserPoolId` from the Mail stack outputs:

   ```sh
   aws cognito-idp admin-create-user --user-pool-id <UserPoolId> --username you@example.com --user-attributes Name=email,Value=you@example.com Name=email_verified,Value=true --message-action SUPPRESS --profile thoughtreps-prod-legacy
   aws cognito-idp admin-set-user-password --user-pool-id <UserPoolId> --username you@example.com --password '<password>' --permanent --profile thoughtreps-prod-legacy
   ```

6. Send a test mail to hello@thoughtreps.com; confirm it lands in the mail bucket and forwards.

Then update INTEGRATIONS.md with the new status and output values.

To add a mailbox, edit `mailboxAddresses`/`forwardTo` in `infra/lib/env-config.ts`, redeploy Mail, and rerun `deploy-mail-web.sh` (it reads the `MailboxAddresses` output, so there is no separate `VITE_` edit).
