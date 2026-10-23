# Thought Reps — Device Sync Harness Spec

Status: draft, 2026-10-19. Closes phase 4 of the sync spec ("A real iPhone and iPad pair, join and recover") with a scripted run on real devices instead of a manual one, and becomes the regression suite for phase 6.

## Goal

`scripts/sync-device-integ.sh` runs two-device sync scenarios on a real iPhone and iPad (USB or Wi-Fi), against the dev stack with real auth on, with one human touch per run at most (the Sign in with Apple sheet). Every run leaves nothing behind: no vaults, accounts, device records or keys on the server, the devices or iCloud. It reuses `SyncScenarioTests` and the role/marker pattern of `scripts/sync-integ.sh`.

## What changes from the simulator harness

| Simulator harness (`sync-integ.sh`) | Device harness |
|---|---|
| Marker files in a host folder (simulators share the Mac's filesystem) | A small HTTP coordinator on the Mac's LAN address; the test runners `PUT`/`GET` markers |
| Local server on `127.0.0.1` (DynamoDB Local, thrown away) | Dev stack in AWS (`SyncAccountService.devBaseURL`), which persists, so every run cleans up after itself |
| Dev-secret auth only | Dev-secret for data scenarios; real sessions (App Attest + Sign in with Apple) for account scenarios |
| `simctl` create/boot/uninstall | `devicectl` install/uninstall/file copy; devices picked by UDID |
| Status snapshot read from the shared folder | Status snapshot pulled from the app container with `devicectl device copy from` |

## Phases

Each phase merges to main on its own, with the simulator harness still passing. Phases 1 and 2 need no human touch.

| # | Phase | Builds | Done when | Estimate |
|---|---|---|---|---|
| 1 | **Device runner and cleanup** | Coordinator, HTTP signals, device script, cleanup ledger, reset action | The three existing scenarios pass on the iPhone and iPad twice in a row, and the second run's preflight finds nothing left from the first | 1 day |
| 2 | **Data sync scenarios** | Seed hook, scenarios D1 to D6, snapshot pass check | D1 to D6 pass on devices; the outbox is empty and counts match on both sides after each | 1 day |
| 3a | **Account hooks** (built) | Invite as text, `SyncLabID` accessibility ids, dev delete-account route | Sync lab exposes everything A1 to A6 need to read or tap | half a day |
| 3b | **Account scenarios** (built, not yet run on devices) | `SyncAccountScenarioTests` A1 to A6, the script's `account` mode, ledger entry for the account vault | A1 to A6 pass on devices with at most two Sign in with Apple taps per run; phase 4 of the sync spec is done | half a day |
| 4 | **Once before ship (manual)** | Nothing; a checklist | Real QR scan, iCloud Keychain join and a look at the Sync lab screens, done once on the iPhone and iPad | 1 hour |

## Phase 1: device runner and cleanup

1. **Coordinator** (`scripts/sync-coordinator.py`, stdlib only, run with `python3 -I`). Binds the Mac's LAN IP on a random port. `PUT /<run>/<scenario>/<name>` stores a marker (optional small body), `GET` returns it or 404, `DELETE /<run>` clears. In memory, a random run token in the path so a stale runner can't touch a new run, exits with the script. No other routes.
2. **Test-side signals.** `SyncScenarioTests.signal`/`waitForSignal` get a transport switch: files when `TR_SYNC_DIR` is set (simulators, unchanged), HTTP when `TR_SYNC_COORDINATOR` is set (devices). Same 0.3 s poll, same timeouts. Signals may carry a string body, not only an `Int64` (needed for the invite and recovery code in phase 3).
3. **Device script** (`scripts/sync-device-integ.sh`).
   - Inputs: `TR_DEVICE_A`, `TR_DEVICE_B` (UDIDs from `xcrun devicectl list devices`), defaulting to the only connected iPhone and iPad.
   - Preflight: both devices paired, Developer Mode on, unlocked; `Config/Local.xcconfig` present; the Mac's LAN IP found; the cleanup sweep (below) passes.
   - `build-for-testing` once for `generic/platform=iOS` with the `ThoughtRepsSyncIntegration` scheme.
   - Per scenario: reset both devices, run both runners in parallel with `xcodebuild test-without-building -destination id=<udid>` and `TEST_RUNNER_`-prefixed variables (`TR_SYNC_ROLE`, `TR_SYNC_COORDINATOR`, `TR_SYNC_URL`, and the dev secret and a fresh `test-` vault for dev-secret scenarios), pull both status snapshots, clean up, print PASS/FAIL. Logs and `.xcresult` bundles go in a run directory.
   - Scenarios that need a reinstall between steps are split into phases; the script runs the `devicectl` step between them.
4. **Cleanup.** Nothing a run creates may outlive it.

   | Leftover | Where | Cleaned by |
   |---|---|---|
   | Dev-secret vaults (records, blobs) | Dev DynamoDB and S3 | The scenario's end erases the vault through the existing dev route `POST /dev/vaults/{id}/erase`; backstop: the next run's preflight sweep replays the ledger |
   | Real accounts, vaults, device records | Dev | The account scenario ends with "Delete sync data" (phase 3); the sweep finishes any that didn't |
   | Server device slots (3-device limit) | Dev | Covered by the above; preflight fails early if this device's account still lists devices |
   | Local Keychain key, App Attest key id, `sync.sqlite` | Device (the Keychain item survives uninstall) | A DEBUG "Reset sync test state" action in the Sync lab, run by the script before and after each scenario via a launch argument, then an uninstall |
   | iCloud Keychain copy | The tester's iCloud | The test launch turns "Save sync key to iCloud Keychain" off; Delete sync data removes it too |
   | App data | Device | Uninstall |
   | Coordinator, run directories | Mac | The coordinator exits with the script; run directories older than 7 days are deleted at start |

   - **Ledger.** The script appends every vault and account it creates to `ledger.jsonl` in the run directory before using it.
   - **Exit trap.** On any exit (pass, fail, Ctrl-C, a crashed runner) the script cleans every ledger entry and resets both devices.
   - **Sweep.** Preflight replays the ledgers of earlier runs that didn't finish clean and refuses to start if either device still holds a sync key after a reset.
   - **Final check.** A run ends by asserting every ledger entry is cleaned; a failed cleanup fails the run even if the scenarios passed.
5. **Scenarios:** the three existing deleted-while-open scenarios, unchanged, now on devices.

## Phase 2: data sync scenarios (dev secret, no human touch)

The engine's logic is already covered by convergence tests against fakes. These prove each kind of data crosses the real server between real devices. Each runs both directions where it applies.

1. **D1 Content.** A creates a thought, B sees it; B edits it, A sees the edit; A deletes it, B loses it. Tags added and removed follow.
2. **D2 State and schedule.** Pin, archive, unarchive, change the interval, snooze, switch to Learn mode and press Got it; the other side matches.
3. **D3 Images and files.** An inline image, a gallery and a file block arrive intact (bytes match by hash). Needs a DEBUG launch hook that seeds an image or file thought, since XCUITest can't drive the photo picker (closes the TODO.md item).
4. **D4 Links.** A link block arrives and opens its target; deleting the target leaves the link dangling cleanly on both sides.
5. **D5 Conflicts.** Each side syncs only when the test asks the app to (sync-now notification, probe button or foregrounding), so the tests can edit before either syncs:
   - clean merge (edits in different paragraphs): both edits survive, no copy;
   - overlapping edit: a conflict copy on both devices;
   - edit vs. delete: the outcome matches the sync spec's rule on both sides.
6. **D6 Volume.** The seed hook makes 500 thoughts on A; B ends with 500. One record over 64 KiB takes the blob path and arrives intact.

**Pass check after every scenario (phases 2 and 3):** both status snapshots show an empty outbox, nothing parked or held, and the same thought count. UI assertions alone don't pass a scenario.

As built (phase 2):

- **Seed hook** (`SyncTestSeed`, DEBUG): launch argument `-TRSeedSyncTestData kind[,kind...][:nonce]`, run in `SyncDebugSession` once the outbox is on and before the engine starts. Kinds: `image`, `gallery` (3 images), `file`, `bulk` (500 thoughts tagged `#syncbulk`), `large` (150 KB body, over the 64 KiB inline limit), and `learn` (a Learn thought already due, so Got it needs no day of waiting). It creates through `ThoughtStore`, and a relaunch with the same kind and nonce seeds nothing (`syncTestSeedApplied` in UserDefaults).
- **Snapshot** (`StatusSnapshot`, the file and the device probe): adds `thoughts`, `digest` (`SyncContentDigest`: SHA-256 over per-thought hashes of id, body, blocks, tags, pin/archive state, conflict link, schedule fields and every image's and file's byte hash; the three change clocks and each tag's color and color clock are included; view counters and thumbnails are left out), `parked` and `held` (the held-record table plus every held-back thought counter). Written after each cycle, computed off the main actor.
- **Pass check:** `scripts/sync-pass-check.py` (both scripts call it) compares the two pulled snapshots. Inside the tests, every scenario ends with `assertConverged` (digests equal through the markers, outbox empty, nothing parked or held, cursor at the server head), and every hand-over is `publishStep`/`awaitStep`: the actor pushes and publishes its digest, the other side syncs until it has that digest.
- **D5** runs with `THOUGHTREPS_SYNC_MANUAL=1` (DEBUG): no debounce and no 30 s head check, so the engine runs only at launch, on foreground and when the test asks. Edit vs. delete is two tests, one per order, since the sync spec's rule depends on which came later: delete then edit keeps the thought, edit then delete removes it.
- Edits rewrite the whole body (select all, retype) because typing after a tap next to a tag replaced the tag word, so caret placement was unreliable. Select all goes through the edit menu (long press, "Select All"), because Cmd-A needs a hardware keyboard and on devices the text was inserted instead of replacing (Cmd-A is only a last resort). The field's value is checked against the intended body; on a mismatch the test clears from the end and retypes (up to 3 tries). `createThought` checks its text too.
- `SyncScenarioTests` launches every app with the DEBUG-only `THOUGHTREPS_UITEST_PLAIN_TYPING=1`, which turns off Writing Tools, autocorrect, spell check, smart quotes/dashes and inline prediction on the editor's text view, so typed text lands as typed. Release behavior is unchanged.
- D4 and the four D5 scenarios pass on a real iPhone and iPad (iPad in Windowed Apps).
- Scenario names: `testD1_content`, `testD2_stateAndSchedule`, `testD3_imagesAndFiles`, `testD4_links`, `testD5_cleanMerge`, `testD5_overlappingEdit`, `testD5_editAfterDeleteKeepsTheThought`, `testD5_deleteAfterEditRemovesTheThought`, `testD6_volume`. Data scenarios get twice the scenario timeout, volume four times.

## Phase 3: account scenarios (real auth)

Split in two: 3a (app and server hooks, built) and 3b (tests, script mode, ledger; built, not yet run on devices).

As built (3a, all DEBUG-only):

- `syncInviteQR` is the QR image's id and its `accessibilityValue` is the full invite payload.
- "Join with invite text" (`syncInviteTextField`, `syncInviteTextJoin`, shown when signed out) goes through `SyncPairingInvite(parsing:)` -> `requestJoin(.invite(...))` -> `JoinGate` -> `/pair`. The invite and recovery fields clear after a join attempt, since they hold secrets.
- About 30 ids in `SyncLabID` (`SyncLabView.swift`): recovery code, recovery join, JoinGate confirm/Merge/Erase, device rows (name, this-device marker, rename/remove and their confirmations), leave and erase-and-leave, resume prompt/Resume/Forget, Delete sync data, sign-in, account vault, engine phase and attention, account message. Status rows are single accessibility elements; tests read their `.value` (the code, the vault id, the status text; `serverRefused` reads "Server refused: ..."). Device row ids repeat per row: Rename exists only on this device's row, Remove only on others.
- Server (`thoughtreps-aws`, documented there): dev-only `POST /dev/vaults/{id}/delete-account` deletes the account that owns a vault, like `DELETE /account` but with the dev secret instead of Sign in with Apple.
- Failed-run cleanup: the UI's "Delete sync data" when a device still holds the account, plus a sweep that calls `delete-account` for ledger vaults (3b).

As built (3b):

- `SyncAccountScenarioTests` is its own class (A1 to A6, in order; the first failure skips the rest), on a shared base `SyncDeviceTestCase` (`SyncDeviceTestSupport.swift`) extracted from `SyncScenarioTests`.
- Run modes: no args or `data` runs the 12 data scenarios; names outside that list (including `testA*`) are rejected. `account` runs A1 to A4, reinstalls B, then A5 and A6; `account --through A3` stops early. `account` can't mix with data names.
- Two legs around the reinstall: A1 to A4 in one `xcodebuild` per device, then the script uninstalls and installs B without the reset launch (the Keychain item survives), then A5 and A6. The pass check compares snapshots after A4 (and after A5 if the run ends there); after A6 both devices are signed out, so the tests' own checks are the evidence.
- Taps on A: `ACTION: approve Sign in with Apple on <A>` at A1, and `ACTION: if a Sign in with Apple sheet appears on <A>, approve it` at A6 (the delete needs a sign-in within 10 minutes).
- A2's offline-thought check: B writes a local-only thought while out of the vault, and after joining with Erase it must be gone.
- A5 fallback: if the Keychain item doesn't survive the reinstall, the test skips ("Keychain item didn't survive reinstall"), prints it prominently, and B rejoins by recovery code. The run still ends PASS with A5 skipped.
- Cleanup: A signals the account vault id only after "Vault created."; the script ledgers it with `"account": true`. Cleaning calls dev-only `POST /dev/vaults/{id}/delete-account` (no tap), then the erase, from the exit trap, the next run's sweep and the final check. A 200 from delete-account after A6 passed fails the run.
- Late-approval recovery: if Sign in with Apple was approved after the test gave up, the vault exists but was never signaled. In account mode the closing "Reset sync test state" reports the deleted key's vault id (`forgottenVaultID`, a DEBUG field in `SyncTestReset`'s result), and the script ledgers and cleans it. The run fails ("open the Sync lab on A and Delete sync data") only if a vault was suspected and neither path found it.
- Secrets: invites and recovery codes go to a private file outside the run directory (umask 077, removed on exit) and join the same-length `*` redaction and at-rest check, plus a 24-character prefix of each, since logs hold truncated copies.

The plan below was the design for 3b; the notes above are what was built.

1. **Invite as text (DEBUG, Sync lab only).**
   - `SyncInviteSheet`'s QR image gets the payload as its `accessibilityValue` in DEBUG, so device A's test can read `thoughtreps-pair:v1:...`.
   - The Sync lab gets "Join with invite text" (next to "Join by scanning a QR code"): a text field that feeds the same `SyncPairingInvite(parsing:)` -> `JoinGate` -> `/pair` path as a scan. Only the VisionKit decode is skipped.
2. **Recovery code as text.** "Show recovery code" already displays it; A's test reads it and signals it; B types it into "Join with recovery code". No app change expected beyond accessibility identifiers.
3. **Manual step.** When a scenario reaches Sign in with Apple, the test waits up to 3 minutes for the sheet to finish and the script prints `ACTION: approve Sign in with Apple on <device>`. Scripting the passcode fallback is out of scope.

Scenarios:

1. **A1 Create and invite-join, merge.** A signs in (manual tap) and creates a vault; B has its own seeded thoughts; A shows an invite; B joins with the invite text and picks Merge. Both end with both sets of thoughts.
2. **A2 Recovery-code join, erase.** B leaves; A reads the recovery code; B joins with it and picks Erase. B ends with only A's thoughts.
3. **A3 Devices.** Both devices list two devices; A renames itself, B sees the new name; A removes B; B's engine stops with `serverRefused` and its Sync lab says so.
4. **A4 Leave and erase-and-leave.** B leaves (keeps thoughts); B rejoins, then erase-and-leaves (no thoughts). A keeps syncing throughout.
5. **A5 Reinstall resume.** B is in the vault; the script uninstalls and reinstalls B (keeps the Keychain item); B shows "Resume syncing with this vault?"; Resume brings the thoughts back.
6. **A6 Delete sync data.** A deletes sync data (may need a second Sign in with Apple tap on 403 `reauthentication_required`); both devices keep their thoughts and show signed out. This is also every account scenario's cleanup.

A1 to A6 run in order in one session. `/pair`, the device routes and leave need only App Attest, so B never signs in with Apple; A needs Sign in with Apple at A1, and `DELETE /account` needs one within the last 10 minutes, so A6 likely needs a second tap.

## Phase 4: once before ship (manual)

- Pair by scanning a real QR code (VisionKit decode).
- Join from the iCloud Keychain copy (Apple controls the timing, so it isn't scripted).
- Look over the Sync lab screens on both devices (TODO.md: not yet reviewed by a human on a device).

## Rules it keeps

- All app changes are DEBUG-only and live in the Sync lab or launch hooks; nothing ships. The share extension and release builds are untouched.
- The app itself makes no new network calls: only the test runner talks to the coordinator. The app talks only to the dev API and presigned S3, as today.
- Invites and recovery codes cross the LAN only for throwaway dev vaults; the coordinator binds the LAN address, holds markers in memory and exits with the run. Logs never print the dev secret or vault key, and redact invites and recovery codes. The test runners' own logs (`.xcresult`) would hold the dev secret and vault key, so the script overwrites them with same-length `*` after each scenario and on exit and fails the run if any remain.
- The simulator harness keeps working unchanged; a `sync-integ.sh` run is part of every phase.

## Open questions (resolved during the build)

1. Resolved: `/pair`, the device routes and leave need only App Attest; only creating the account and `DELETE /account` need Sign in with Apple, and the delete needs one within the last 10 minutes. A2 to A5 need no tap, and a full run needs two taps on A (A1 and A6).
2. Resolved on devices (2026-10-19): iOS shows the Local Network prompt only for a foreground app, and the background runner was silently refused ("Local network prohibited", -1009) and never listed in Settings. `SyncScenarioTests.reachCoordinator` now brings the runner forward, retries the coordinator for up to 2 minutes and taps Allow; the grant sticks because only the app is uninstalled between scenarios. ATS needs no exception: the Xcode-generated runner's Info.plist sets `NSAllowsArbitraryLoads` and has an `NSLocalNetworkUsageDescription`. Also seen: a floating window (an iPad picture-in-picture player) covering Save fails a scenario, so close other apps before a run.
3. Whether reinstall keeps the Keychain item on current iOS for a development-signed app (it should; A5 and the reset action depend on it). Fallback built (A5 skips and B rejoins by recovery code); still to confirm on a device.
4. Resolved: a dev-secret scenario erases its vault with the existing `POST /dev/vaults/{id}/erase` (dev stage only, dev secret; erases records and blobs, 404 for an unknown vault). The app creates the vault itself at start (`POST /dev/vaults`), so the script only records it in the ledger.

## Estimate

About 3 days plus fixes: phase 1 one day, phase 2 one day, phase 3 one day, phase 4 an hour.

## As built: cleanup and probes

- The harness records every `test-` vault in a ledger and erases it through the dev-only `POST /dev/vaults/{id}/erase` (exit trap, next-run sweep, final check that fails the run). Account-mode vaults (real Sign in with Apple) are ledgered too and cleaned through the dev-only `POST /dev/vaults/{id}/delete-account`, then the erase.
- Before each uninstall it runs the DEBUG-only "Reset sync test state" (Sync lab, or launch arg `-TRResetSyncTestState <nonce>`; `SyncTestReset`), which deletes the local vault key, sync App Attest key id and `sync.sqlite`, and the iCloud Keychain copy only for `test-` vaults. UI tests launch with `syncSaveKeyToICloudKeychain` off.
- The UI test runners read the status snapshot through the DEBUG-only `syncStatusProbe` accessibility element (`THOUGHTREPS_SYNC_STATUS_PROBE`; a relative status file path resolves inside the app container). Only the runners talk to the Mac's coordinator (`scripts/sync-coordinator.py`); the app adds no network calls.
