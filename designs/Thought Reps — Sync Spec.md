# Thought Reps — Device Sync Spec (iPhone ↔ iPad, AWS)

Status: ready to build, updated 2026-10-14 (first draft 2026-10-10). Not built. Phase 0 and phase 1 can start now; the account decision (section 2) gates only phase 4. Open decisions are listed at the end.

Changes on 2026-10-14: iPad has shipped (section 0); 3-way merge is in v1, with conflict copies as the fallback, marked by a new `Thought.conflictOfID` field (sections 8 and 8a); key storage on the device (section 5); clarified how the push condition and `headSeq` work (section 7); Android notes (section 13); new phasing.

This builds on what's already in the repo:

- The direction in the `TODO.md` sync entry: a server that only stores end-to-end encrypted records.
- The sync prep in `75930ad`: per-group change clocks, tombstones, view counters merged by max.
- The App Attest, Lambda, DynamoDB and presigned S3 setup behind the export link.

Principles:

- **The app stays account-free.** Nothing about sync appears or touches the network until the user turns sync on. Anything account-like is asked for only at that moment.
- **End-to-end encrypted.** We never hold the key (unless a user later opts into server escrow, section 6), so we can't read thoughts.
- **Apple-only first** (iPhone + iPad), with the choices below made so non-Apple devices can come later without a migration (section 13).

## 0. Prerequisite: a real iPad app (done)

The iPad app is built and in 1.0: the three-column `SplitRootView` on regular width, keyboard shortcuts, drag-and-drop images. Nothing left here for sync.

## 1. Shape of the system

```
iPhone ─┐                       ┌─ API Gateway HTTP API (sync.thoughtreps.com/api/v1)
        ├─ HTTPS, App Attest ──►│   Lambdas: auth, vault, push, pull, blobs, appstore
iPad  ──┘                       ├─ DynamoDB SyncTable (accounts, vaults, devices, records)
        └─ presigned PUT/GET ──►└─ S3 SyncBlobBucket (encrypted images)
```

- **New stack:** `ThoughtReps-prod-Sync`, in the same `prod` stage and us-east-1, with the same shared-account rules as Share.
- **Shared code:** App Attest code moves from `lambda/export-link/shared/` to a common `lambda/shared/`.
- **Device registration:** keep one device registry. Share exports its device table, so a device attests once for both features.
- **Dev stage:** add a `dev` stage (`ThoughtReps-dev-Sync`) with a test-only auth bypass, because App Attest doesn't work in the simulator. Without it there's no way to test two simulators syncing. The bypass must never be in prod; a CDK assertion test should enforce that.

## 2. Turning sync on: account or not (undecided)

Two options. Both keep the main app account-free and both are end-to-end encrypted; they differ in what "Turn on sync" asks for.

**A. No account.** Turning sync on creates a vault; other devices join by scanning a QR code from a paired device.

- Nothing personal is stored.
- Recovery depends on the recovery code or iCloud Keychain (section 6).
- We have no way to reach the user (lapse warnings only in the app).

**B. Sign in with Apple, only when sync is turned on (leaning this way).** The account owns the vault and the subscription.

- **Joining:** the iPad usually has the same Apple ID, so joining is signing in. With the key in iCloud Keychain (section 5) there's no QR code.
- **Contact:** we get an email, possibly an Apple private relay address: lapse warnings, support, and a recovery alert if server escrow ever exists.
- **No passwords** to build or store.
- **Later:** Sign in with Apple also has a web flow that works in browsers and on Android (section 13).
- **Costs:** the App Store privacy answers add "Contact info, linked to the user" (sync users only), and account creation means Apple requires in-app account deletion; "Delete sync data" does that (section 12).

**An account doesn't change who holds the key.** Signing in proves who you are; it doesn't give a new device K. With B the key still travels by iCloud Keychain, QR or recovery code (section 5).

```
Sign in with Apple ─┐
Sign in with Google ├─► Account (our userId) ─► Vault (encrypted data)
Email link (later) ─┘     + subscription           ▲
                          + email                  │ readable only with K,
                                                   │ held on devices, never by us
```

- **Many sign-in methods, one account.** Each method is an `ID#<provider>#<sub>` row pointing at the same `userId`. The account answers "who are you and have you paid"; the key answers "can you read it."
- **What B adds besides escrow:** a way to reach the user (lapse warnings, support); the subscription survives a lost key cleanly (the account owns both, so resetting the vault is trivial); a signed-in device without the key can be told "you have synced data but no key; reset it?"; a natural place to link Google later.
- **If A is chosen,** add an optional email stored on the vault for lapse warnings only. Moving a subscription to a new vault after a lost key then goes through `originalTransactionId` from a restored purchase.

The rest of this spec is written for **B**, with notes where A differs. Under A, drop the account rows and auth routes; the vault id plus device membership is the identity.

## 3. Devices and membership

- **There's no main device.** Every paired device holds K and is an equal member. Any device can add another (iCloud Keychain, or "Add a device" QR) and any device can remove another, which covers a lost phone when only the iPad is left.
- **The vault outlives the device that created it.** Retire the first iPhone and the others carry on.
- **Removing a device** cuts off its API access. It still knows K. Real revocation means rotating the key, which re-encrypts every record, so that waits for phase 2.
- **Cap:** 10 devices per vault, to limit abuse and quota.
- **Pairing shares everything,** including blurred blocks. The QR screen says so plainly: "Only scan this with your own devices." Sharing with another person is a non-goal and would need a different design.

## 4. Encryption

- **One vault key K:** 256 bits, generated on the first device. Keychain storage per section 5.
- **Keys derived from K (HKDF-SHA256):**
  - `K_rec`: AES-256-GCM key for records.
  - `K_blob`: AES-256-GCM key for images.
  - `K_idx`: HMAC key that turns `(type, uuid)` into a record key the server can't read, so the server never sees thought ids.
  - `K_auth`: proves knowledge of K to the server (a verifier is stored at vault creation), so a device holding only the recovery code can join (section 6).
- AAD = `vaultId | recordKey | payloadVersion`, so the server can't swap ciphertexts between records.
- This reuses the export link's CryptoKit code, with the same pattern as its `TRB1` framing.
- **Encrypted per record, not as one blob.** Each thought is two records (content and meta), each encrypted on its own with a fresh random nonce; each tag is a record; settings is one record; each image is one blob. Editing one thought uploads one small record. The full-backup snapshot in section 9 is only an optional speedup for first sync, not how data is stored.
- **What the server still sees:** the number of records, their sizes, when something changed and which opaque record changed. Not text, tags or thought ids. Option: pad payloads to size buckets so short and long thoughts look alike (cheap, decide before shipping).

## 5. Getting the key onto a new device

In order of preference:

1. **iCloud Keychain (main path).** K is a synchronizable Keychain item, which iCloud Keychain end-to-end encrypts. On a device signed into the same Apple ID it's just there: sign in and you're syncing. A toggle, "Save sync key to iCloud Keychain," defaulted on with an explanation.
2. **QR code from a paired device.** Fallback when iCloud Keychain is off (and the main path under option A).
   - The paired device creates an invite: the server stores `SHA256(pairingSecret)` with a 10-minute TTL, single use.
   - The QR code holds `vaultId`, `pairingSecret` and K. The new device scans, attests, and calls `POST /pair`.
   - The key goes from screen to camera and never touches the server.
3. **Recovery code.** K shown as a code to write down, on a "Sync key" screen. Joining with it uses `K_auth` (section 6).

**A device can join by QR without signing in.** The native Sign in with Apple sheet always uses the Apple Account the device is signed into, with no way to pick another. On a device with a different Apple ID (a shared family iPad, a work phone), signing in would create a second, empty account. So the QR invite alone is enough to join: it proves vault membership, the device attests with App Attest, and it gets the vault's entitlement. Linking a second Apple ID (as section 13 does for Google) or the web sign-in flow (`ASWebAuthenticationSession`, any Apple ID) stay possible but aren't the main path.

iCloud Keychain is a convenience, not a dependency: sync works with QR and the recovery code alone. It can be off for many reasons (turned off in Settings, not signed into iCloud, a different or managed Apple ID, the toggle switched off), so both fallbacks ship in v1. When iCloud Keychain is off, setup makes writing down the recovery code a required step.

### Key storage on the device

- **Synced item** (iCloud Keychain on): `kSecAttrSynchronizable = true`, holding K and the `vaultId` together, so a new device can find its vault without asking.
- **Local item** (iCloud Keychain off, or after joining by QR or code): `kSecAttrSynchronizable = false`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
  - "AfterFirstUnlock" lets `BGAppRefreshTask` read the key while the phone is locked; "WhenUnlocked" would quietly break background pulls.
  - "ThisDeviceOnly" keeps it out of backups and device-to-device migration. A new phone set up without iCloud Keychain gets the key by QR or code, and setup says so.
- **Reinstall:** Keychain items survive deleting the app. A key with no matching `sync.sqlite` state is treated as stale: ask before using it.
- **Turning sync off or leaving the vault** deletes the key from that device (and the synced item only if the user leaves the vault on every device).
- No Secure Enclave wrapping; the Keychain's hardware-backed protection is enough.

## 6. Recovery

- **Recovery code + iCloud Keychain in v1.** If every device is lost, signing into a new iPhone or iPad with the same Apple ID restores the Keychain, so the key and the vault come back. If the Apple ID is lost too, the written code still works.
- **Joining without a paired device:** the server lets a device join with an invite **or** by proving knowledge of K (`K_auth` against the stored verifier). Holding the key is membership.
- **If every device is lost and both the Keychain and the code are gone,** the server data can't be read. The UI and the help center say so plainly.
- **Later, only if people ask: server escrow,** as a separate opt-in.
  - The device sends K wrapped with an AWS KMS key (encryption context = `vaultId`); the wrapped key is stored on the vault.
  - Recovery: a new device attests and signs in (Sign in with Apple); a recovery Lambda unwraps K and the device joins. Only that Lambda has `kms:Decrypt`; CloudTrail logs every decrypt. About $1/month for the one key.
  - Safeguard: recovery waits about 7 days, and every paired device plus the account email gets "Recovery requested — cancel." This is why escrow needs an email.
  - Trade-off: for opted-in users it stops being end-to-end. We could read their thoughts, and so could anyone who breaks into the AWS account (shared with strands prod, which raises the stakes) or makes a legal demand. Privacy policy, App Store privacy answers and help center would need an opt-in version of the promise.

## 7. Server data model (DynamoDB, on-demand, one table)

| pk | sk | contents |
|---|---|---|
| `U#<userId>` | `ACCOUNT` | our own account id; email (if any); entitlement (expiry, store, original transaction id); vault id |
| `ID#apple#<sub>` | `ID` | sign-in method → `userId` (later `ID#google#…`, `ID#email#…`) |
| `V#<vaultId>` | `HEAD` | `headSeq`, `epoch`, `prunedBeforeSeq`, live-record count, byte usage, `K_auth` verifier |
| `V#<vaultId>` | `KW#<method>` | optional wrapped copies of K (later: sync password, passkey PRF, escrow); none required |
| `V#<vaultId>` | `D#<keyId>` | device name, added/last-seen times |
| `V#<vaultId>` | `R#<recordKey>` | `seq`, `deleted`, `payload` (ciphertext, inline up to ~64 KB, otherwise an S3 pointer) |
| `INV#<hash>` | `INV` | invite, TTL attribute |
| `DEV#<keyId>` | `VAULT` | which vault the device belongs to |

- **Change feed:** an LSI `bySeq` sorts records by `seq`. A pull is `Query pk=V#x, seq > cursor, ConsistentRead`.
- **Free compaction:** an edited record gets a new `seq`, so a pull only ever returns the latest version.
- **Size cap:** an LSI caps each vault at 10 GB. Text only, a vault with 300k thoughts is well under that, and images live in S3.

**Push is one transaction:**

- `TransactWriteItems` (at most 100 actions and 4 MB, so batches of up to 99 records, also limited by bytes).
- The first action moves `HEAD` forward on the condition `headSeq = :expected` (and adjusts the live-record count). `:expected` is the push Lambda's own read of `HEAD` just before the transaction, not the device's cursor; if another push lands in between, the Lambda re-reads and retries. A device never needs the vault's latest seq to push.
- Each record is a put with `seq = expected + i` and the condition `attribute_not_exists(seq) OR seq = :baseSeq`, where `baseSeq` is the seq of the version the device last synced for that record.

**`headSeq` in short:** one counter per vault, shared by all its devices and moved only by the server. Each device keeps its own cursor (highest seq pulled) in `sync.sqlite`. A seq says what changed since; it never decides who wins a merge (the clocks do, section 8).

That gives two guarantees:

1. **Commit order matches seq order.** A puller can never move its cursor past a write that lands later with a lower seq. This is the classic change-feed bug, and the reason not to use a GSI or allocate seqs on their own.
2. **Compare-and-swap per record.** A device can't overwrite a version it hasn't seen. A failed condition returns 409 with the conflicting keys. The client pulls, merges, then pushes again.

When two devices push at the same moment, one of them simply retries.

## 8. Records (encrypted JSON, versioned like the backup format)

| Record | Contents | Merge (on the client; the server can't read it) |
|---|---|---|
| `thought.content` | body, blocks, image refs (id, blob name, size, order), `createdAt`, `updatedAt` | If only one side changed since the last synced base, take it. If both did, **3-way merge** against the base (section 8a). If the changes overlap, the later `updatedAt` stays as the thought and the other side becomes a **conflict copy** (section 8a). Text is never lost. |
| `thought.meta` | `nextDueAt`, interval, mode, `learnIntervalDays` (+ `scheduleChangedAt`); pin, archive, `conflictOfID` (+ `stateChangedAt`); `viewCount`, `lastViewedAt` | Each group wins on its own clock; counters take the max. This is the `GroupWins` logic `importThoughts` already has. Never conflicts: opening a thought on both devices, or pinning on one while requeuing on the other, just merges. |
| `tag` | name, color, `updatedAt` | Last writer wins on `updatedAt` (the same as `mergeTagColors`). |
| `settings` | `defaultIntervalDays` | Last writer wins. |
| deletion | `deleted: true` + `deletedAt` on both thought records | Deleted, unless content was edited *after* `deletedAt`. In that case it comes back, which avoids losing an offline edit. |

- **Why two records per thought:** opening a thought requeues it, which changes the schedule group. Keeping that separate means a view doesn't re-upload the body, and content and schedule never conflict with each other.
- **Kept per device, not synced:**
  - Theme, font, reminder on/off and time.
  - Rating and reminder prompt state.
  - Reminders stay per device on purpose. Otherwise iPhone and iPad would both buzz. The new-device default is off.
- **Clock skew:** the clocks are device wall-clock times. When applying remote records, the store remembers the highest clock it has seen. Local writes then use `max(now, highestSeen + 1 ms)`, a lite hybrid logical clock. That's internal to `ThoughtStore`, and the Scheduler functions stay pure.
## 8a. Merging content, and conflict copies

### When the merge runs

Only when a pulled `thought.content` record lands on a thought this device has also changed and not yet pushed (it's in the outbox). The same path handles a 409 on push: pull, then merge.

1. **No unpushed local change:** apply the remote version as is. This is the common case.
2. **Unpushed local change:** take three versions: **base** (last synced content, in `sync.sqlite`), **local** (the store now), **remote** (just pulled).
3. **Merge blocks by id first:** blocks added, removed or reordered on either side. A block removed on one side and edited on the other is an overlap.
4. **Then merge text line by line inside each markdown block** (diff3, built on Swift's `CollectionDifference`). Image tokens (`![](img:<uuid>)`) are whole lines. Link, file and gallery blocks merge at the block level only; a gallery's image list merges as a set with the remote order winning.
5. **Clean merge:** write the result through `applyRemote` with a new content clock (section 8, clock skew). The base becomes the remote version; the outbox entry stays, so the merged result is pushed with `baseSeq` = the remote seq.
6. **Overlap anywhere:** no partial merge. The later `updatedAt` stays as the thought, and the other side's full content becomes a conflict copy.

Only the device that lost the race merges; the other device receives the merged result as a plain remote change. So the merge doesn't need to be deterministic across devices, only correct. The merge is a pure function (`ContentMerge.merge(base:local:remote:) -> .merged(Content) | .conflict`) in `Sync/`, tested on its own.

### Conflict copies

- **Field:** `Thought.conflictOfID: UUID?` (default nil), pointing at the original. A plain id like `Block.linkedThoughtID`: no relationship, may dangle, never points at itself. It's state, so it's in the state group (`stateChangedAt`) and the meta record, and both devices see it. Added to `SchemaV1` before the freeze (phase 0), so sync needs no migration.
- **The copy:** a new thought with the losing side's blocks and tags (images referenced, not re-uploaded: blob names de-duplicate). Due now. Its own outgoing links come with it; links *to* the original stay on the original.
- **Timeline:** a "Needs a look" section above Pinned lists thoughts with `conflictOfID` set, each showing the original as a card. A fetch with a predicate on `conflictOfID != nil`, never an in-memory filter.
- **Resolve sheet, three choices:**
  - **Keep this version:** the copy's content replaces the original's (a content write on the original), and the copy is deleted.
  - **Keep the original:** the copy is deleted.
  - **Keep both:** `conflictOfID` is cleared; the copy becomes a normal thought.
- **Original deleted meanwhile** (dangling id): the sheet offers only "Keep" (clears the field) or "Delete".
- **Backup format:** `conflictOfID` goes in the thought record and merges with the state group on import. Added before any build has shipped, so no `formatVersion` bump.
- **Integrity:** `IntegrityChecker` gains "`conflictOfID` never equals the thought's own id." Reminders don't count copies differently; they're ordinary due thoughts.

## 9. Client (`ThoughtReps/Sync/`)

- **`SyncEngine` (actor):** pull, then download blobs, then apply, then push the outbox.
- **Sync state in its own SQLite file**, like the search index:
  - `sync.sqlite`: cursor, `recordKey → (entity id, server seq, clock fingerprint, base hash, base content)`, the outbox, blob state.
  - Kept out of backups.
  - **No SwiftData schema change**, so `SchemaV1` can be frozen at launch and still get sync without a V2.
  - If the file is lost, the only cost is a full resync. Merges are clock-based, so reapplying everything is idempotent.
- **Outbox, same pattern as search:** every `ThoughtStore` writer that changes content, schedule, state, tags or deletes submits `sync.enqueue(ids)`, alongside its reindex.
- **`SyncReconciler`:** at launch, compares each thought's clock fingerprint to `sync.sqlite` and repairs drift. This mirrors `SearchReconciler`.
- **Applying remote changes goes through `ThoughtStore`:** a new `applyRemote(...)` that shares `performImport`'s per-group merge, so search reindexing, `persist()` rollback rules and the IntegrityChecker all still apply. Content that collides with an unpushed local change goes through the 3-way merge first (section 8a).
- **The tombstone table is now actually read.** Server tombstones older than 180 days are pruned. A device offline longer than that gets a 410 and does a full resync: pull everything, push whatever the server doesn't have.

### When sync runs

**Sending changes (reliable):**

- About 2 s after a local write (debounced).
- Leaving the app right after an edit asks iOS for extra background time (`beginBackgroundTask`, about 30 s) to finish the push, so an edit on the iPhone is normally on the server before the iPad is picked up.
- Big image uploads use a background `URLSession`, which keeps running after the app is suspended.

**Getting the other device's changes (on open, plus best effort):**

- On launch and whenever the app comes to the foreground. A handful of changes takes well under a second.
- `GET /head` every 30 s while the app is open.
- `BGAppRefreshTask` in the background, when iOS chooses (based on usage, maybe a few times a day; never after a force-quit).
- **No silent push in v1.** Truly reliable background pulls need APNs, which breaks the "local notifications only" rule and is throttled anyway. A pull on open is fast, and that's when the other device gets looked at.
- Side effect: each device builds reminders from its own data, so an un-synced iPad can show stale counts. Another reason reminders stay per device.

### First sync (turning sync on with an existing library)

1. Turning sync on queues **every** thought, tag and the settings record. "Not in `sync.sqlite`" means "not uploaded yet."
2. The engine pages through thoughts by id (`fetchLimit` pages), encrypts and pushes 99 per transaction, and records the server seq and clock fingerprint after each confirmed push.
3. Image blobs go up **before** the content records that reference them, so a pulling device never gets a thought whose image is missing.
4. The outbox is on disk, so a killed app resumes where it stopped. Settings shows progress ("Uploading 12,340 of 48,000").
5. A second device can join during the upload; it gets thoughts as they arrive and keeps pulling until caught up.

**Checking it actually finished:**

- **On the device:** the reconciler confirms every local thought has a `sync.sqlite` entry whose fingerprint matches its current clocks; anything missing or stale is re-queued.
- **On the server:** the live-record count on `HEAD` is compared to what the device expects (2 per thought, plus tags, plus settings). A mismatch triggers a full re-check.
- "Sync complete" shows only when both agree.

**Scale:** 300k thoughts is about 600k records, roughly 6k requests. Fine in the background; images dominate the time. If it's too slow, phase 2 adds a bootstrap snapshot: upload an encrypted `.thoughtreps` file (the export link already does this) and start the log from its seq. CAS still holds, because a record with no row counts as "at the snapshot."

### Joining with a device that already has thoughts

1. Joining pulls everything from the vault and merges it in by id. Different ids add up, so nothing is overwritten.
2. Then it queues every local thought with no `sync.sqlite` entry, so the new device's own thoughts go up too.
3. Before joining it asks: "This iPad has 120 thoughts. Merge them with your synced thoughts, or erase this iPad first?"
4. The vault's default interval wins.

Turning sync off and on, or switching vaults, clears `sync.sqlite` and queues everything again. Clock-based merges make re-uploading safe, with no duplicates.

### Erase everything

On a synced device, ask which is meant:

- **"Erase this device and leave sync":** local only.
- **"Erase on all devices":** `DELETE /vault`, and `epoch` goes up. Other devices see the new epoch on their next pull and erase too.

This answers the open question in TODO.md.

## 10. Images

- **Blob name:** `HMAC(K_idx, plaintext bytes)`, which de-duplicates without the server seeing content. The bytes are encrypted with `K_blob` and stored at `s3://…/v/<vaultId>/b/<name>`.
- **Upload:** `POST /blobs/upload-urls` with names, sizes and SHA-256 values. The server returns presigned PUTs only for missing blobs, with `x-amz-checksum-sha256` enforced. Uploads use a background `URLSession`.
- **Thumbnails:** not synced; regenerated on download, as backup import already does.
- **Pull order:** records come down, blobs download, *then* the record is applied. This keeps the IntegrityChecker invariant that image data is present.
- **Cleanup:** the server can't tell which blobs are still in use. A device with complete state occasionally sends the list of live blob names, and the server deletes anything else older than 30 days.
- **Bucket:** unversioned, scoped by vault prefix, no `ListBucket` for the Lambdas. Same pattern as the export bucket.
- **Format:** images are HEIC today. Fine on Apple and Android, but most browsers can't decode it. Decide before sync ships whether to switch the default to JPEG or convert in a future web client (section 13).

## 11. API (`/api/v1`, JSON, schemas in `lib/sync/schemas.ts` mirrored in Swift)

| Route | Purpose |
|---|---|
| `POST /auth/apple` | Sign in with Apple identity token (verified against Apple's published keys) + App Attest assertion → session token; creates the account on first use |
| `POST /session` | App Attest assertion → session token (refresh for an already-signed-in device) |
| `POST /vaults` | Create the account's vault (needs a subscription; see 12) |
| `POST /vaults/{id}/invites` | Create a pairing invite (QR fallback) |
| `POST /pair` | Join a vault with an invite or a `K_auth` proof |
| `GET/DELETE /vaults/{id}/devices[/{keyId}]` | List or remove devices |
| `POST /push` | `{records:[{key, baseSeq, deleted, payload}]}` → `{headSeq, seqs}` or 409 `{conflicts}` |
| `GET /pull?since=&limit=500` | → `{records, nextSeq, headSeq, more, epoch}`; 410 if `since < prunedBeforeSeq` (full resync) |
| `GET /head` | `{headSeq, epoch}`, a cheap poll |
| `POST /blobs/upload-urls`, `/blobs/download-urls`, `/blobs/gc` | Image transfer and cleanup |
| `POST /entitlement` | Signed App Store transaction from the device → verified and stored on the account |
| `DELETE /account` | Delete the account, vault, records and blobs ("Delete sync data"; also "Erase on all devices") |
| `POST /appstore/notifications` | App Store Server Notifications v2 |

- **Session tokens:** HMAC, about 1 hour, bound to `userId`, `keyId` and `vaultId`. Push and pull send a bearer token, avoiding a challenge round trip on every call.
- **Limits:** per-route throttles, payload size caps, a storage quota per vault (for example 10 GB of images), and the same status-code vocabulary as the export link.

## 12. Subscription, email and account deletion

`TODO.md` proposes about $2.99/month.

- **Purchase:** a StoreKit 2 auto-renewing subscription. **Apple never gives us the buyer's email or Apple ID.** A subscription reaches the server as:
  - `originalTransactionId`: stable across renewals and restores.
  - `appAccountToken`: a UUID the app sets when the purchase starts. We set it to the `userId` (under option A, the `vaultId`), so every signed transaction and server notification is tied to the right account with no email involved.
- **Verification:** the server verifies the JWS (`@apple/app-store-server-library`) and stores expiry, store and transaction id on the account.
- **Renewals:** App Store Server Notifications v2 keep the expiry current.
- **When it lapses:** pushes are refused, devices keep everything locally, and server data is deleted after 30 days, with a warning in the app (and by email under option B).
- **Email:** only from Sign in with Apple under option B (may be a private relay address). Used for lapse and deletion warnings, support, and escrow recovery alerts. Never required by the subscription itself.
- **Account deletion:** account creation means Apple requires in-app deletion. "Delete sync data" (`DELETE /account`) removes the account, vault, records and blobs.
- **Cost:** DynamoDB, Lambda and S3 per user are cents a month (images at about $0.023 per GB-month), so the price covers it easily.
- **Rule from the launch plan:** don't take away anything buyers already have. The app stays fully local without sync.

## 13. Non-Apple devices later

Apple-only v1 builds one of each piece; these choices keep the rest additive.

- **Accounts:** our own `userId` with linked sign-in methods (`ID#apple#…` now; `ID#google#…`, `ID#email#…` later). Sign in with Apple's web flow already works in browsers and on Android; Android-only users would get Google sign-in, email magic links or passkeys. Token checks run in a Lambda against each provider's published keys, about the size of the App Attest code; Cognito could do it but is more moving parts than needed.
- **Moving the key without iCloud Keychain** (the real gap off Apple), stored as optional `KW#` rows:
  1. QR from a paired device: already cross-platform.
  2. Sync password, like Obsidian Sync: K wrapped with an Argon2id-derived key and stored on the server. Still end-to-end, but one more password, and forgetting it loses the data.
  3. Passkeys with the PRF extension: a passkey produces a secret that wraps K, and passkeys sync through iCloud Keychain, Google Password Manager and 1Password. Most elegant, but support is newer (iOS 18+) and uneven; revisit when non-Apple support is built.
- **Paying:** Google Play on Android, Stripe on the web. The entitlement belongs to the account and records its store, so paying on iPhone gives sync on Android too. Check Apple's current guideline wording on services used across platforms before relying on that.
- **Moving the key between Android devices:** Android Block Store (Google's end-to-end encrypted store for small secrets) is the closest match to iCloud Keychain. It only covers Android to Android; the first Android device still joins by QR or recovery code.
- **Apple account, Android device:** Sign in with Apple's web flow on Android returns the same `sub` when it runs under the same developer team, so it finds the same `ID#apple#…` row and account. **v1 action:** register the Services ID for the web flow under the same team.
- **Avoiding a second account:** a Google sign-in has nothing tying it to the Apple one. So joining by QR also links the account: the invite proves vault membership, and the server attaches the new device's sign-in (`ID#google#… → userId`). The Android sign-in screen leads with "Used Thought Reps on iPhone? Scan the code from your iPhone." A new account with no vault can be merged into the real one. Settings nudges "Add another way to sign in," so losing one provider doesn't lock the user out.
- **Device check:** Android has no App Attest; the server needs a Play Integrity verifier alongside it.
- **Two stores:** the entitlement accepts any active store; warn if both are billing.
- **Data:** the record format is already neutral (JSON, AES-256-GCM, HKDF-SHA256). The one format choice to revisit early is HEIC images (section 10); Android decodes HEIC from Android 9.

## 14. Testing

- **Convergence tests (the important ones):**
  - N in-memory stores and an in-process fake server that implements the push/pull/CAS contract.
  - Randomized operations, sync order, dropped responses, injected save failures and clock skew.
  - Check that all stores end up identical and that the IntegrityChecker and SearchIndexChecker stay clean.
  - Extends the existing seeded randomized tests.
- **Merge tests (`ContentMerge`):**
  - Table tests: non-overlapping edits in one block, edits in different blocks, add/remove/reorder blocks, image tokens, link and file blocks, overlaps of every kind.
  - Properties on random edits: a clean merge contains every line either side added and none either side removed; merging with an unchanged side returns the other side exactly; image tokens are never duplicated or dropped; the result passes IntegrityChecker.
  - Convergence runs with concurrent edits to the same thoughts, so conflict copies and merges both appear.
- **Server tests (jest):**
  - Transaction ordering, CAS conflicts, `ConsistentRead` pulls.
  - Pairing (single use, expiry) and `K_auth` joins.
  - Sign in with Apple token verification, entitlement JWS verification.
  - The 410 prune path, quota, entitlement checks, account deletion.
  - A CDK assertion that the dev auth bypass is missing from prod.
- **Manual:** two simulators against the `dev` stage, then a real iPhone and iPad against prod, because App Attest only works on devices.
- **Developer mode (two real devices):** a hidden "Sync lab", only in debug and TestFlight builds (never App Store; App Review rejects hidden features), turned on from Settings.
  - Uses its own throwaway library and test vault on the `dev` stage with real App Attest, so real thoughts are never touched.
  - One device starts a run and the other joins by scanning its QR code (the real pairing flow). They coordinate through a test-run record on the server (turn, step, seed), so it also works across Wi-Fi and cellular.
  - Scripted scenarios: seeded random edits on both; same thought edited offline on both, in different paragraphs (expect a clean merge) and on the same line (expect a conflict copy); delete vs. edit; images uploaded and downloaded once; a ~10k-thought first sync, interrupted and resumed; joining with existing thoughts.
  - Fault switches: offline, drop the next response, clock skew, slow network.
  - At the end each device posts a fingerprint (a hash of every record) and runs IntegrityChecker and SearchIndexChecker; the screen shows pass or fail, which records differ, and a shareable log.

## 15. What else has to change with it

- **Privacy:** both `PrivacyInfo.xcprivacy` files, `privacy.ts`, and the App Store privacy answers (contact info for sync accounts under option B). Check whether E2E-encrypted data counts as "collected" under Apple's definitions.
- **CLAUDE.md:** the network rule gets the sync host.
- **Docs:** a new help article (turning sync on, devices, recovery key and iCloud Keychain, conflict copies, erase choices, deleting sync data), and `INTEGRATIONS.md` for the new stack.
- **App Review:** subscription terms, a restore-purchases button, a link to the terms of use, in-app account deletion.

## Phasing

Each phase merges to main behind a DEBUG-only flag; nothing is user-visible until phase 6. About 9–11 weeks in total. The engine comes first because it's the riskiest part and is fully testable without AWS: if convergence can't be made solid, that shows in phase 1, before any infrastructure cost.

| # | Phase | What gets built | Done when | Estimate |
|---|---|---|---|---|
| 0 | **Schema prep (before the freeze)** | `Thought.conflictOfID` in `SchemaV1`, the backup record, the import merge (state group), an IntegrityChecker rule, a regenerated `default.store` fixture, randomized tests. No UI. | Tests pass; a backup round-trips the field | ½ day |
| 1 | **Sync engine, no network** | `ThoughtReps/Sync/`: `sync.sqlite` (cursor, outbox, base content), outbox hooks in every `ThoughtStore` writer, `applyRemote` sharing `performImport`'s merge, `ContentMerge` (3-way merge, section 8a), conflict copies, the skew-safe clock, `SyncReconciler`, first-sync paging. All against an in-process fake server implementing the push/pull/CAS contract. | Convergence tests pass (N stores, concurrent edits, dropped responses, save failures, clock skew); merge table and property tests pass; IntegrityChecker and SearchIndexChecker stay clean | 3 weeks |
| 2 | **Server, dev stage, text only** | `ThoughtReps-dev-Sync`: DynamoDB table with the `bySeq` LSI, push (transaction + CAS), pull, `/head`, the test-only auth bypass; App Attest code moved to `lambda/shared/`. A basic Sync lab screen. | Two simulators sync text against dev; jest covers ordering, CAS conflicts and the 410 path; a CDK test proves the bypass isn't in prod | 1.5 weeks |
| 3 | **Images** | Blob bucket, presigned upload and download, HMAC blob names, background `URLSession`, blob-before-record ordering, blob cleanup | Images sync both ways, upload once, and are never missing on the receiving side | 1 week |
| 4 | **Identity and keys** | Sign in with Apple (or vault creation under A), App Attest sessions, Keychain key (synced and local items, section 5), QR pairing that also links the account, recovery code, `K_auth` join, device list and removal, erase choices, "Delete sync data". The "Needs a look" timeline section and resolve sheet. Prod stack deployed. | A real iPhone and iPad pair, join and recover; the full Sync lab runs on both | 2 weeks |
| 5 | **Subscription** | StoreKit 2 subscription, `appAccountToken`, `/entitlement` JWS check, App Store Server Notifications v2, deleting data 30 days after a lapse, restore purchases | Sandbox subscribe, renew, lapse and restore all behave correctly | 1 week |
| 6 | **Launch prep** | Privacy manifests, `privacy.ts`, App Store privacy answers, help article (including conflict copies), `INTEGRATIONS.md`, CLAUDE.md network rule, App Review items, TestFlight with real device pairs | Testers sync real libraries for a week with no divergence | 1 week + beta |

**Decisions needed before each phase:**

- **Before 0 and 1:** none.
- **Before 3:** HEIC or JPEG as the image default.
- **Before 4:** account (B) or no account (A). The only decision that changes code.
- **Before 5:** subscription add-on or included, and the price.
- **Before 6:** whether to pad record sizes.

**Later, not in v1:** bootstrap snapshot for very large libraries, key rotation (real device revocation), server escrow, Android (section 13).

## Open decisions

1. **Account when sync is turned on (B, Sign in with Apple) or no account (A)?** Leaning B, still thinking it over. Needed before phase 4.
2. **Subscription add-on, or included?** Recommended: an add-on, so the paid-once app stays whole.
3. **Reminders per device, off by default on new devices?** Recommended: yes.
4. **iCloud Keychain key storage defaulted on?** Recommended: yes, with an explanation.
5. **Pad record sizes to buckets?** Cheap; decide before shipping.
6. **HEIC or JPEG as the image default** before phase 3 (matters for a future web client).
7. **Server escrow:** not in v1; add only if people ask, as a separate opt-in.

Decided on 2026-10-14: 3-way merge in v1 with conflict copies as the fallback, marked by `conflictOfID` (section 8a). The iPad app has shipped.
