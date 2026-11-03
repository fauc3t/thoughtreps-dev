# Thought Reps — Sync Setup Flow Spec (production UI)

Status: approved 2026-11-03; building round 6a. Mockups: `designs/Thought Reps — Sync Setup Mockups.html`.

Sync ships in 1.0 (decided 2026-11-03), sold as the tier1 subscription with a 1-month free trial (an App Store introductory offer). The engine, server, pairing and account code exist (Sync Spec, phases 0 to 5 server side) but can only be driven from the DEBUG Sync lab. This spec covers the screens and plumbing a release build needs. The Sync lab stays as a DEBUG tool alongside it.

## Principles

- **Nothing changes until the user turns sync on.** Settings shows one "Sync" row. The app makes no sync network calls, signs in with nothing and attests nothing until then.
- **Settings keeps the standard iOS look** (CLAUDE.md themes rule): grouped `Form`, native Sign in with Apple button, StoreKit's own purchase sheet.
- **One sentence of explanation per step, written plainly.** No crypto vocabulary. "Your thoughts are encrypted on your devices before they're uploaded. We can't read them."
- **Every destructive action names what it keeps.** "Your thoughts stay on this iPhone."

## Entry point

Settings gets a new section above Backup:

| State | Row | Value text |
|---|---|---|
| Off | Sync | Off |
| Syncing | Sync | Uploading 1,240 of 4,800 / Up to date |
| Needs the user | Sync | ⚠︎ Needs attention (red dot on the Settings tab too) |

The row pushes `SyncSettingsView`, which shows the setup screen when off and the status screen when on.

## Turning sync on: three paths

```
Sync (off) ──"Continue with Apple"──► Sign in with Apple
                                   │
                ┌──────────────────┼─────────────────────────┐
         account has no vault   account has a vault       device already in
                │                   │                     another vault (409)
          Subscribe (skipped     key in iCloud Keychain?  → "This iPhone is syncing
          if already paid)          │yes        │no          with another account"
                │                Join prompt   "Unlock your synced thoughts":
          Create vault + key        │          Scan QR / Enter recovery code /
                │                   │          Support (lost key)    
          Key safety step           └─────┬─────┘
                │                      Join prompt (merge or erase, Sync Spec §9)
                └─────────► Status screen (first upload / download progress)

Sync (off) ──"Join with a QR code or recovery code"──► Scan / Enter code ──► Join prompt ──► Status
             (no sign-in: another Apple ID, or a family iPad; the vault's account must be paying)
```

### S1. Sync (off)

- Header illustration: two device outlines with a thought card moving between them, using the system tint.
- Title "Sync your thoughts", body: "Keep your thoughts, tags and images the same on your iPhone and iPad. They're encrypted on your devices before they're uploaded, so nobody else can read them, including us."
- Facts list: "Up to 3 devices", "1 GB of storage", "1 month free, then $2.99/month" (price from StoreKit, localized, never hard-coded).
- Primary: the native `SignInWithAppleButton` labelled "Continue with Apple" (style follows the color scheme).
- Secondary: "Join with a QR code or recovery code".
- Footer: "Thought Reps works fully without sync. Signing in only creates a sync account; your email is used for subscription and account notices." Links: Terms of Use, Privacy Policy.

### S2. Sign in with Apple

Native sheet. Request scope `.email` only (no name). The client splits today's `signInAndCreateVault` into `signIn` → decide → (`subscribe`) → `createVault`, because creating a vault is gated by the subscription (402).

Errors: cancel returns to S1 silently; network failures show an inline banner with Try Again; App Attest unsupported (rare, old or jailbroken device) shows "Sync isn't available on this device."

### S3. Subscribe (only when `GET /entitlement` says `none`, `expired` or `revoked`)

A sheet over the setup screen:

- Title "Start your free month".
- What's included (the same three facts), then "After the free month, $2.99/month. Cancel anytime in Settings › Apple Account › Subscriptions."
- Primary: "Try It Free" (or "Subscribe" when the user isn't eligible for the introductory offer, which StoreKit reports via `isEligibleForIntroOffer`).
- "Restore Purchases" text button.
- Footer: Terms of Use (EULA), Privacy Policy (both required by App Review 3.1.2).

Purchase passes `appAccountToken` from `GET /entitlement`, then posts the signed transaction to `POST /entitlement`. A purchase that succeeds with Apple but fails our POST is retried automatically (`Transaction.updates` listener plus a retry on next launch); the user isn't asked to pay twice. 409 `subscription_other_account`: "This subscription is already used by another sync account." with a Contact Support link.

Using `SubscriptionStoreView` is an option, but a custom view gives control over the copy and the trial wording; the purchase itself is still Apple's sheet.

### S4. Create the vault and keep the key safe

After a successful purchase (or an already-active entitlement), the vault is created with a spinner ("Setting up sync…"), then one screen:

- Title "Keep your sync key safe".
- Body: "Your thoughts are locked with a key that only your devices have. If you lose every device, you'll need this key to get them back."
- Toggle "Save in iCloud Keychain" (on by default): "Your other devices signed in to this Apple Account can join without a code."
- Button "Show Recovery Code" opens S8.
- With the toggle **off**, "Continue" is disabled until the recovery code has been shown and confirmed (Sync Spec §5: writing it down becomes required).
- With the toggle **on**, "Continue" is enabled; the recovery code stays reachable from the status screen.

### S5. Second device, same Apple ID

After sign-in the account already has a vault:

- **Key found in iCloud Keychain:** the standard join prompt ("Join this sync vault?" / "Thoughts from your other devices will be added to this iPhone.", then merge or erase if the device has thoughts; Sync Spec §9). No subscription step: the vault's entitlement covers the device.
- **No key:** "Unlock your synced thoughts" screen. "This Apple Account already syncs thoughts from another device. To read them here, use that device to add this one." Buttons: "Scan QR Code" (camera; the other device shows Add a Device), "Enter Recovery Code", and at the bottom "Lost your key? Contact Support" (see Decisions).
- **Device limit reached** (409 `device_limit` on the invite, shown on the inviting device): "You're syncing 3 devices, the most this plan allows. Remove one to add another."

### S6. Join without signing in

From S1's secondary button: a choice of "Scan QR Code" or "Enter Recovery Code", then the join prompt. `/pair` stays open without a subscription, so a device that joins a lapsed vault joins and then shows the "Sync is paused" state; no separate screen. The recovery code field accepts 80 Crockford characters with or without spaces or dashes, validates the checksum as you type, and shows "That code doesn't look right. Check each group of four." before any network call.

### S7. Sync (on): the status screen

Sections, top to bottom:

1. **Status** (header, no section title): a large symbol and one line.
   - Up to date: "Up to date", subline "Last synced 2 minutes ago".
   - First sync: "Uploading 1,240 of 4,800 thoughts" with a progress bar; subline "You can keep using the app. Sync continues when you come back to it."
   - Offline or retrying: "Waiting for a connection".
   - Attention states, each with one action (table below).
2. **Devices** (x of 3): one row per device, "This iPhone" first, then each with "Last synced 3 hours ago". Swipe or tap to Rename or Remove. "Add a Device…" opens the QR sheet (`SyncInviteSheet`, "Only scan this with your own devices.").
3. **Storage**: a meter, "312 MB of 1 GB used". At 90% or more: footer "Almost full. Thoughts with new images will wait until space is freed."
4. **Sync key**: "Save in iCloud Keychain" toggle; "Show Recovery Code" (S8).
5. **Subscription**: "Free trial until Dec 3" / "$2.99/month, renews Dec 3" / "Ends Dec 3 (won't renew)". "Manage Subscription" (`showManageSubscriptions`), "Restore Purchases".
6. **Leave** (destructive group, each with a confirm that says what stays):
   - "Turn Off Sync on This iPhone": leaves the vault (server call skipped when the device was already removed), clears this device's key, App Attest key id and sync state; thoughts stay; the iCloud Keychain copy stays so the user can come back. One action for both cases (it replaces the Sync lab's "Sign out and forget key").
   - "Erase This iPhone and Leave": the existing erase-and-leave, with its second confirm.
   - "Delete Sync Account…": `DELETE /account` (Apple-required in-app deletion). Confirm: "This deletes your synced thoughts from our server and stops sync on every device. Thoughts on your devices stay. Your App Store subscription isn't cancelled by this; manage it in Settings." Needs a fresh Sign in with Apple when the server asks (`reauthentication_required`). Needs a typed `DELETE` confirmation, and its screen says plainly that without another device or the recovery code the synced copy is the only copy of thoughts not on this device.

### Attention states

| Engine or server state | Line | Action |
|---|---|---|
| 402 `subscription_required` with `purgeAt` | "Sync is paused. Your subscription ended." / "Your synced copy will be deleted on Jan 2. Everything on this iPhone stays." | Resubscribe (opens S3; StoreKit decides trial or plain wording) |
| Epoch changed after a purge | "Your synced copy was removed after the subscription ended. Everything on this iPhone is safe." | Resubscribe to upload again |
| Epoch changed after another device's erase | "Sync was reset from another device." | Upload this iPhone's thoughts / Turn off sync |
| 413 storage full (`quotaExceededThoughts`) | "Storage is full. 12 thoughts are waiting." | Manage subscription (bigger tiers later) |
| `updateRequired` | "Some thoughts came from a newer version of Thought Reps." | Open App Store |
| Removed by another device (401/403) | "This iPhone was removed from sync." | Turn Off Sync on This iPhone (the same action as in Leave, without the server call) |
| Other `serverRefused` | "Sync stopped. Try again later or contact support." | Contact Support (feedback form, no thought content) |
| Held thoughts (oversized, missing attachments, blobs) | footer only: "3 thoughts couldn't sync yet." | none; details in DEBUG Sync lab |

### S8. Recovery code

Gated by device owner authentication (Face ID, Touch ID or passcode via `LocalAuthentication`). Shows 20 groups of 4 in a monospaced grid, with Copy, Save to Files (a small text file) and Print. Footer: "Anyone with this code can read your synced thoughts. Keep it somewhere safe and private." When reached from S4 with iCloud Keychain off, a "I've Saved It" button confirms and returns.

### S9. Lapse and trial notices outside Settings

- Trial ending and renewal are Apple's emails; the app adds nothing.
- After a lapse, one dismissible card at the top of the Timeline: "Sync is paused. Your synced copy will be deleted on Jan 2." → opens Settings › Sync. Shown again weekly and in the last 7 days daily. The Settings row's red dot stays until resolved.

## Plumbing a release build needs

- **Remove the DEBUG gates** around the account service, transport and sync state; keep the Sync lab, the dev bypass, test seeds and resets DEBUG-only (`SyncDebugSession`, `SyncTestReset`, `SyncTestSeed`).
- **Base URL:** release builds use one prod host, never the `execute-api` URL; DEBUG builds keep the environment picker. The host is `sync.thoughtreps.com` (Decisions).
- **`SyncController`** (app-level `@Observable` singleton, like `AppNavigation`): owns engine start and stop, triggers (launch, foreground, debounced writes, 30 s head check, `BGAppRefreshTask`), the published status for the Settings row, and the attention mapping above. The Sync lab reads from it rather than building its own engine.
- **StoreKit 2:** products, intro-offer eligibility, purchase with `appAccountToken`, `Transaction.updates` listener posting to `POST /entitlement`, restore. A StoreKit configuration file for simulator and unit tests.
- **Engine changes** already queued in TODO.md: 402 is a hold, not a stop; 413 holds growing thoughts but keeps pushing deletes and shrinks; purge-epoch message; decode the phase-5 wire fixtures.
- **Camera usage string** for QR scanning: "Thought Reps uses the camera to scan a sync QR code from your other device."
- **Background:** register `BGAppRefreshTask`; move blob transfers to a background `URLSession` (TODO.md 3b follow-up).
- **Privacy:** both privacy manifests, `privacy.ts` (Sign in with Apple email, device records, encrypted content, subscription status), App Store privacy answers ("Contact info, linked to the user" for sync users). Help center article for sync.

## Build rounds

1. **6a Plumbing (done):** DEBUG gates, base URL, `SyncController`, split sign-in and vault creation, 402/413 engine handling, wire fixture decoding. Sync lab moved onto `SyncController`. Tests.
2. **6b Screens:** S1, S2, S4 to S8 and the Settings row, against dev with the subscription gate off.
3. **6c Subscription:** StoreKit, S3, the subscription section, lapse and purge states, storage meter, Timeline notice. Gate on in dev.
4. **6d Launch prep:** background session, privacy, help article, camera string, App Store Connect products and notification URLs, the support admin script for account deletion (`thoughtreps-aws`), prod `realAuthEnabled` and session secret, device harness driving the real screens.
5. **Then the deferred device checks** (pairing steps 3 to 5, harness A5 and A6 and a full run, Needs a look) on the production flow, and the TestFlight week.

## Decisions (2026-11-03)

1. **API host:** `sync.thoughtreps.com`, an API Gateway custom domain on the prod Sync stack in `thoughtreps-aws` (dev gets its own, e.g. `sync.dev.thoughtreps.com`, or keeps its `execute-api` URL in DEBUG). `transfer.thoughtreps.com` stays the export-link and feedback host. Release builds hard-code only `https://sync.thoughtreps.com/api/v1`.
2. **Lost key, "Start over": a support case** (decided 2026-11-03). Deleting the account can destroy the only way back into the old synced thoughts, so a device without the key can't do it alone. The "Unlock your synced thoughts" screen's last button is "Lost your key? Contact Support":
   - **Screen first** (not an alert): "Your synced thoughts can only be read with your sync key, and we never have it. If any of your devices still syncs, or you have your recovery code, use that instead." Buttons for what to try first: "Check iCloud Keychain Again", "Scan QR Code", "Enter Recovery Code"; then "Contact Support".
   - **The request** goes through the existing feedback route (App Attest, no thought content), prefilled and carrying the account's `userId` and this device's key id so support can find it. Reply goes to the Sign in with Apple email.
   - **Support** confirms by email that the user has no device or recovery code left and understands the synced copy is deleted for good, then deletes the account with an admin script in `thoughtreps-aws` (the `DELETE /account` path by `userId`, logged). The `TX#` claim goes with it.
   - **After,** the user signs in again, gets a new account and vault, and the app reposts StoreKit's current entitlement (`Transaction.currentEntitlements` → `POST /entitlement`), so the subscription follows with no new charge. Thoughts on the device are never touched; other devices on the old vault are cut off and rejoin.
   - **App Review risk:** Apple requires account deletion inside the app and allows a support flow only in regulated industries. Devices with the key have "Delete Sync Account" in-app (S7), but a user whose only device lacks the key can't delete in-app. If Review objects, the fallback is a self-serve "Delete Sync Account" on that screen with the typed `DELETE` confirmation.
3. **Reminders:** per device; off by default on a device that joins a vault.
4. **Paywall:** a custom view (S3); the purchase sheet is Apple's.
5. **First-upload progress:** a count only, no time estimate.

Mockup notes: during a first upload the other status sections show normally; the subscription row after a purge reads "Ended Dec 3"; at 100% storage the footer reads "Storage is full. Thoughts with new images are waiting."
