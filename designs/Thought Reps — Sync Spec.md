# Thought Reps — Device Sync Spec (iPhone ↔ iPad, AWS)

Status: building, updated 2026-10-16 (first draft 2026-10-10). Phases 0 to 2 are done (the sync engine, the dev-stage server, the Swift HTTP transport and the two-simulator integration script). Phase 3 (images): server rounds 3a and 3c are live on dev, the client's 3b is built and awaiting tests, 3d is pending. Phase 4: round 4a (real server auth) is built server-side, not deployed. The account decision (section 2) gates only phase 4's client. Open decisions are listed at the end.

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

- **New stack:** `ThoughtReps-<env>-Sync`, built in the separate `thoughtreps-aws` repo (a CDK Pipeline with separate pipeline, dev and prod accounts), not in this repo's `infra/` and not in the shared account.
- **Shared code:** the App Attest verification code is copied (not moved) from this repo's `infra/lambda/export-link/shared/` into `thoughtreps-aws`'s `infra/lambda/shared/` (done in 2a, unwired until phase 4); the old stacks keep their own copy.
- **Device registration:** keep one device registry. Share exports its device table, so a device attests once for both features.
- **Dev stage:** a `dev` account/stage (`ThoughtReps-dev-Sync`) with a test-only auth bypass, because App Attest doesn't work in the simulator. Without it there's no way to test two simulators syncing. The bypass must never be in prod; a CDK assertion test should enforce that.

## 2. Turning sync on: account or not (decided: B, 2026-10-16)

Two options. Both keep the main app account-free and both are end-to-end encrypted; they differ in what "Turn on sync" asks for.

**A. No account.** Turning sync on creates a vault; other devices join by scanning a QR code from a paired device.

- Nothing personal is stored.
- Recovery depends on the recovery code or iCloud Keychain (section 6).
- We have no way to reach the user (lapse warnings only in the app).

**B. Sign in with Apple, only when sync is turned on (chosen).** The account owns the vault and the subscription.

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

**Decided 2026-10-16: B, built so A's path stays open.** Turning sync on signs in with Apple, which creates our own `userId`; the account owns the vault and the subscription. Every sign-in method is only an `ID#<provider>#<sub>` row mapping to that `userId`, so Google or an email link later is one more row, never a migration. A login maps to the account and vault, never to the key: K reaches a new device only by iCloud Keychain, QR or recovery code. Once the account is paying, a device can also join with the QR invite alone, without signing in (section 5), which is option A's join for devices on another Apple ID or people who'd rather not sign in.

The rest of this spec is written for **B**. Notes on A describe the QR-only join, which B keeps.

## 3. Devices and membership

- **There's no main device.** Every paired device holds K and is an equal member. Any device can add another (iCloud Keychain, or "Add a device" QR) and any device can remove another, which covers a lost phone when only the iPad is left.
- **The vault outlives the device that created it.** Retire the first iPhone and the others carry on.
- **Removing a device** cuts off its API access. It still knows K. Real revocation means rotating the key, which re-encrypts every record, so that waits for phase 2.
- **Cap:** 10 devices per vault, to limit abuse and quota.
- **Pairing shares everything,** including blurred blocks. The QR screen says so plainly: "Only scan this with your own devices." Sharing with another person is a non-goal and would need a different design.

## 4. Encryption

- **One vault key K:** 256 bits, generated on the first device. Keychain storage per section 5.
- **Keys derived from K (HKDF-SHA256, empty salt, `info` = `thoughtreps.sync.v1.<name>`):**
  - `K_rec` (`record`): AES-256-GCM key for sealed records.
  - `K_blob` (`blob`): AES-256-GCM key for every blob: images, files and sealed records too big to go inline (section 10).
  - `K_idx` (`index`): HMAC-SHA256 key behind the opaque names the server sees: record keys `base64url(HMAC(K_idx, "<type>|<uuid>"))`, asset blob names `base64url(HMAC(K_idx, "blob.<image|file>|<uuid>"))` and record-blob names `base64url(HMAC(K_idx, "blob.record|<recordKey>|<plaintext hash>"))`. All are 43 characters, so the server never sees thought or asset ids.
  - `K_auth` (`auth`): proves knowledge of K to the server (a verifier is stored at vault creation), so a device holding only the recovery code can join (section 6). **Its info string becomes permanent the moment phase 2 derives the verifier from it;** until then nothing depends on it, but the other three already are (they are in every stored byte).
- **Frames** (integers big-endian; `lp(x)` is a `u32` byte count followed by the UTF-8 bytes; `SyncCrypto` is the reference and `SyncGoldenTests` pins every byte):
  - **Record frame:** `"TRS1"` | key generation (1 byte, `1`) | payload version (1 byte) | nonce (12) | ciphertext | tag (16). The ciphertext is AES-256-GCM under `K_rec` of `u32 plaintext length | plaintext | zero padding`. AAD: `lp(vaultId) | lp(recordKey) | u32 payloadVersion | u8 keyGeneration`.
  - **Blob frame:** `"TRSB"` | key generation (1 byte, `1`) | nonce (12) | ciphertext | tag (16), the ciphertext being the data itself under `K_blob`, not padded. AAD: `lp(vaultId) | lp(blobName) | u8 keyGeneration`. A record too big to go inline is its whole sealed record frame sealed this way.
  - **Pointer:** the payload of a record whose sealed frame is in a blob: `"TRP1"` | the 43-character blob name. Anything else after the magic is damage.
  - Every ciphertext gets a fresh random nonce. The AAD binds the vault, the record (or blob name), the payload version and the key generation, so the server can't swap ciphertexts between records, vaults, versions or key generations.
  - **Key generation** is reserved for key rotation (a later phase re-encrypts under a new key and bumps it). A reader that sees a generation it doesn't know parks the record, like a newer payload version.
  - **Unknown magics:** a payload whose first four bytes are `TR` plus anything this build doesn't know (a future `TRS2`, `TRP2`, a blob `TRSC`), or a pointer whose blob opens to such a frame, is parked as "update required" (section 9), never an error. A genuine AES-GCM failure under a known magic is damage or tampering: it stops the cycle, except behind a pointer, where it holds just that thought and backs off.
- **Padding (closes the open question):** the plaintext is padded inside the ciphertext so the whole record frame lands on a size bucket: a power of two from 512 bytes to 1 MiB, then whole MiB. Short and long thoughts below a bucket look alike; the length comes back from the `u32` prefix. A full bucket (65,536 bytes) still fits the 64 KB inline limit. The record's base hash, and so no-op detection, is over the unpadded plaintext, so identical records hash identically on every device. Blobs aren't padded: an image's size is its own, and a record blob already holds a padded frame.
- Wire dates are a `Double` of seconds since 2001-01-01T00:00:00Z (Swift `.deferredToDate`, the reference date), not the backup's ISO 8601, so clocks round-trip losslessly. The record bodies are sync's own frozen Codable types (`SyncWireV1`, and the meta, settings and deletion structs), not the backup format's, so a backup format change can't alter a payload; golden tests pin the exact JSON.
- This reuses the export link's CryptoKit code, with the same pattern as its `TRB1` framing.
- **Encrypted per record, not as one blob.** Each thought is two records (content and meta), each encrypted on its own with a fresh random nonce; each tag is a record; settings is one record; each image is one blob. Editing one thought uploads one small record. The full-backup snapshot in section 9 is only an optional speedup for first sync, not how data is stored.
- **What the server still sees:** the number of records, their size bucket (not their length), when something changed and which opaque record changed. It also sees each record's `deleted` flag in plain text (a push and a pull carry it beside the ciphertext, so the server can keep tombstones), so it knows when something was deleted, and the exact size of each image and file blob. Not text, tags or thought ids.

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
| `V#<vaultId>` | `HEAD` | `headSeq`, `epoch`, live-record count, byte usage, `K_auth` verifier |
| `V#<vaultId>` | `KW#<method>` | optional wrapped copies of K (later: sync password, passkey PRF, escrow); none required |
| `V#<vaultId>` | `D#<keyId>` | device name, added/last-seen times |
| `V#<vaultId>` | `R#<recordKey>` | `seq`, `deleted`, `payload` (ciphertext, inline up to 64 KB sealed, otherwise a `TRP1` pointer to a record blob in S3) |
| `INV#<hash>` | `INV` | invite, TTL attribute |
| `DEV#<keyId>` | `DEVICE` | the device's App Attest public key and counter, environment, and the `userId` it last signed in as |
| `CHALLENGE#<c>` | `CHALLENGE` | one-time App Attest challenge, TTL attribute |

- **Change feed:** an LSI `bySeq` sorts records by `seq`. A pull reads `HEAD` to get h, then queries `pk=V#x, seq BETWEEN since+1 AND h` (see guarantee 1).
- **Free compaction:** an edited record gets a new `seq`, so a pull only ever returns the latest version.
- **Size cap:** an LSI caps each vault at 10 GB. Text only, a vault with 300k thoughts is well under that, and images live in S3.

**Push is one transaction:**

- `TransactWriteItems` (at most 100 actions and 4 MB, so batches of up to 99 records, also limited by bytes).
- The first action moves `HEAD` forward on the condition `headSeq = :expected` (and adjusts the live-record count). `:expected` is the push Lambda's own read of `HEAD` just before the transaction, not the device's cursor; if another push lands in between, the Lambda re-reads and retries. A device never needs the vault's latest seq to push.
- The same action also carries the condition `epoch = :epoch`, where `:epoch` is the epoch the device sent with the push (the one it last pulled). If the vault was erased or replaced in between, the whole transaction is refused (409 `epoch-changed` with the server's epoch) and writes nothing, so a device that missed an "Erase on all devices" can never bring its old records back. The client stops with `epochChanged`, exactly as when a pull shows a new epoch.
- Each record is a put with `seq = expected + i` and the condition `attribute_not_exists(seq) OR seq = :baseSeq`, where `baseSeq` is the seq of the version the device last synced for that record.

**`headSeq` in short:** one counter per vault, shared by all its devices and moved only by the server. Each device keeps its own cursor (highest seq pulled) in `sync.sqlite`. A seq says what changed since; it never decides who wins a merge (the clocks do, section 8).

That gives two guarantees:

1. **A pull only returns fully committed pushes.** AWS documents only read-committed isolation between `TransactWriteItems` and a Query, so a Query can see some items of an in-flight push and not others. Pull therefore reads `HEAD` with a single-Get `TransactGetItems` first. That read is serializable and is cancelled while a write transaction touching `HEAD` is in flight (retried, then 503 `busy`). Every push touches `HEAD`, so a successful read of h means every push up to h has completed. The Query is capped at `seq <= h`, and later pushes show up on the next pull. A puller's cursor therefore never passes a write that lands later with a lower seq, the classic change-feed bug (and the reason not to use a GSI or allocate seqs on their own).
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
- **Clock skew:** the clocks are device wall-clock times. When applying remote records, the store remembers the highest clock it has seen. Local writes then use `max(now, highestSeen + 1 ms)`, a lite hybrid logical clock. That's internal to `ThoughtStore` (`SyncClock`, stored in UserDefaults), and the Scheduler functions stay pure.
  - Monotonic: every stamp past `now` becomes the new `highestSeen`. A remote clock raises `highestSeen` at most to `now + 1 day`, so one wildly wrong device can't push everyone's clocks into the future. Due dates, `createdAt`, `lastViewedAt` and `archivedAt` use real `now`. No-op without sync.
  - **Known limit (accepted):** a device whose clock runs more than a day ahead can have a deletion undone by its own later-stamped edit, because of the `now + 1 day` cap. Phase 2's offset correction narrows it.
  - **Phase 2 (built in 2b, `ServerClockOffset`):** responses carry `serverTime`, and devices stamp with `max(now + offset, highestSeen + 1 ms)`. The first offset needs 3 agreeing samples; a jump over 60 s needs 3 consecutive samples; the offset is bounded to 1 day. While sync is on, every stamp is observed into `highestSeen`, so stamps stay monotonic whatever the offset does. Scheduler and due dates keep the real `now`.
## 8a. Merging content, and conflict copies

### When the merge runs

Only when a pulled `thought.content` record lands on a thought this device has also changed and not yet pushed (it's in the outbox). The same path handles a 409 on push: pull, then merge.

1. **No unpushed local change:** apply the remote version as is. This is the common case.
2. **Unpushed local change:** take three versions: **base** (last synced content, in `sync.sqlite`), **local** (the store now), **remote** (just pulled). A first push whose response was lost has no synced base, so its plaintext is kept in the `attempts` table as the base until a real one is written. **No base at all and differing content:** a conflict copy, never a guess (text is never lost). Known cost: restoring an older backup onto a synced device yields one copy per thought changed since.
3. **Merge blocks by id first:** blocks added, removed or reordered on either side. A block removed on one side and edited on the other is an overlap.
4. **Then merge text line by line inside each markdown block** (diff3, built on Swift's `CollectionDifference`). Image tokens (`![](img:<uuid>)`) are whole lines. Link and file blocks merge whole; galleries merge as a set of images with the remote order winning.
5. **Clean merge:** apply the result through `applyRemote` with a fresh stamped `updatedAt` (section 8, clock skew). The base becomes the remote version; the outbox entry stays, so the merged result is pushed with `baseSeq` = the remote seq.
6. **Overlap anywhere:** no partial merge. The later `updatedAt` stays as the thought, and the other side's full content becomes a conflict copy.

Only the device that lost the race merges; the other device receives the merged result as a plain remote change. So the merge doesn't need to be deterministic across devices, only correct. The merge is a pure function (`ContentMerge.merge(base:local:remote:) -> .merged(Content) | .conflict`) in `Sync/ContentMerge.swift`, tested on its own.

### Conflict copies

- **Field:** `Thought.conflictOfID: UUID?` (default nil), pointing at the original. A plain id like `Block.linkedThoughtID`: no relationship, may dangle, never points at itself. It's state, so it's in the state group (`stateChangedAt`) and the meta record, and both devices see it. Added to `SchemaV1` before the freeze (phase 0), so sync needs no migration.
- **The copy** (`Sync/ConflictCopy.swift`, `ThoughtStore+Conflicts.swift`): a new thought with the losing side's blocks and tags; the later `updatedAt` stays as the original (ties by hash). Its thought, block, image and file ids are new, derived from the original id and the losing content hash, so both devices make the same copy; image tokens are rewritten. Image or file bytes missing locally are dropped from the copy rather than stalling sync. Due now, default schedule. Its own outgoing links come with it; links *to* the original stay on the original.
- **Built in 1c:** `ThoughtStore.keepCopy`, `keepOriginal` and `keepBoth` (taking `now`), and `ThoughtCounts.conflictCopies` with a paged helper. The UI below is phase 4.
- **Timeline:** a "Needs a look" section above Pinned lists thoughts with `conflictOfID` set, each showing the original as a card. A fetch with a predicate on `conflictOfID != nil`, never an in-memory filter.
- **Resolve sheet, three choices:**
  - **Keep this version:** the copy's content replaces the original's (a content write on the original), and the copy is deleted.
  - **Keep the original:** the copy is deleted.
  - **Keep both:** `conflictOfID` is cleared; the copy becomes a normal thought.
- **Original deleted meanwhile** (dangling id): the sheet offers only "Keep" (clears the field) or "Delete".
- **Backup format:** `conflictOfID` goes in the thought record and merges with the state group on import. Added before any build has shipped, so no `formatVersion` bump.
- **Integrity:** `IntegrityChecker` gains "`conflictOfID` never equals the thought's own id" and, from 1c, "Duplicate thought id." Reminders don't count copies differently; they're ordinary due thoughts.

## 9. Client (`ThoughtReps/Sync/`)

- **`SyncEngine` (actor):** pull, then download blobs, then apply, then push the outbox.
- **Sync state in its own SQLite file**, like the search index:
  - `sync.sqlite`: cursor, `recordKey → (entity id, server seq, clock fingerprint, base hash, base content)`, the outbox, blob state.
  - Kept out of backups.
  - **No SwiftData schema change**, so `SchemaV1` can be frozen at launch and still get sync without a V2.
  - If the file is lost, the only cost is a from-scratch pull (cursor 0), which reconciles first. Merges are clock-based, so reapplying everything is idempotent.
- **Outbox, same pattern as search:** every `ThoughtStore` writer that changes content, schedule, state, tags or deletes submits `sync.enqueue(ids)`, alongside its reindex.
- **`SyncReconciler`:** at launch, compares each thought's clock fingerprint to `sync.sqlite` and repairs drift. This mirrors `SearchReconciler`.
- **Applying remote changes goes through `ThoughtStore`:** a new `applyRemote(...)` that shares `performImport`'s per-group merge, so search reindexing, `persist()` rollback rules and the IntegrityChecker all still apply. Content that collides with an unpushed local change goes through the 3-way merge first (section 8a).
- **Tombstones are kept forever** (decided 2026-10-15, reversing the 180-day prune), so any cursor can catch up and there is no resync path. A tombstone is about 100-200 bytes, so even 100k deletions cost pennies. A device that never synced, or lost `sync.sqlite`, pulls from cursor 0 and reconciles first. A stray 410 is treated as a server refusal (the engine stops with `Attention.serverRefused`). If storage ever matters, archive old tombstones to S3 so they stay fetchable, rather than reintroducing resync.
- **Deletions vs edits:** a remote deletion loses to a local content edit after `deletedAt`, and vice versa. A remote deletion for a thought with a local tombstone raises its `deletedAt` to the later value, so devices converge on the max.
- **Unreadable records:**
  - Unknown type, newer payload version, newer key generation or an unrecognized frame magic (section 4): parked sealed in `sync.sqlite`, sync continues, status `updateRequired`; re-tried only when the build's reader version (`SyncCrypto.readerVersion`, one integer bumped whenever the app learns to read a new payload version, key generation or frame magic) changes, and that is noted only once every record that could be read has been applied (the parked list is read a few at a time, never whole). Parked tag and settings records don't block the rest of a push.
  - A thought whose image or file bytes are missing on this device is held back alone (status `missingAttachments`, retried every cycle): its reference is never dropped, since the other devices would then delete an attachment they still have. The 30 s head check ignores entries held back this way (waiting, oversized, missing attachments); it runs a cycle when the head moved past the last pull, when the last cycle failed, or when something pushable is queued.
  - Decrypt or auth failure: the cycle stops with an error.
  - Oversized: a sealed record over 16 MiB (`SyncLimits.maxRecordBytes`, the largest padding bucket) or refused by the server as too large is held and counted in `Status.oversizedThoughts`; the queue never wedges. Users have no thought length cap.
  - Missing blob (including a record-blob pointer's) or a rejected thought: only that thought is held, retried every cycle (an unreadable blob backs off up to 32 cycles). One failing item never stops the cycle.
  - A local edit to a parked or held thought stays queued and isn't pushed until the server's version has applied here; then it merges normally. The rest of its batch still pushes.
- **Apply in sub-batches** of at most 25 MB of image/file bytes (`SyncLimits.maxApplyBytes`); push reads blobs off the main actor.

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

- **Blob name:** phase 1b names blobs `HMAC(K_idx, asset id)`, not content, so a conflict copy that needs new image ids would re-upload. (Content-HMAC de-duplication is the alternative; the server never sees content either way.) The bytes are encrypted with `K_blob` and stored at `s3://…/v/<vaultId>/b/<name>`.
- **Large records:** a sealed record over 64 KB (`SyncLimits.maxInlinePayload`) is sealed with `sealBlob` and uploaded as a blob named by an HMAC of the record key and content hash, before the push; the server row holds a `TRP1` pointer. Superseded pointer blobs are collected by the server's garbage collection (below). A blob download is capped (`getBlob(maxBytes:)`): a sealed record blob at `maxRecordBytes` plus the frame, an image or file at `maxAssetBlobBytes` (25 MB); a bigger one is refused as unreadable and holds only its thought.
- **Upload:** `POST /blobs/upload-urls` with the device's `epoch`, names, sizes and SHA-256 values. A mismatched epoch is refused (409 `epochChanged`) like a push, so a device that missed an erase can't refill the erased vault with orphan blobs; the same epoch rides on the existence check and the download URLs. The server returns presigned PUTs only for missing blobs, with `x-amz-checksum-sha256` enforced. Uploads use a background `URLSession`.
- **Thumbnails:** not synced; regenerated on download, as backup import already does.
- **Pull order:** records come down, blobs download, *then* the record is applied. This keeps the IntegrityChecker invariant that image data is present.
- **Cleanup (garbage collection, server built in 3c; client is round 3d):** the server can't tell which blobs are still in use. A device with complete state (cursor at head) uploads the list of live blob names (`POST /blobs/garbage-collection/live-list-url` returns a presigned PUT; one 43-character name per line, at most 1,000,000), then starts a run with `POST /blobs/garbage-collection {epoch, runId, asOfSeq}`. The worker adds the `TRP1` pointer names to the list, deletes current-epoch blobs that are not live and older than 30 days (re-checking each blob's age right before deleting), deletes every blob of an older epoch whatever its age, stops as stale if the head moves mid-run, and recomputes the vault's byte total. One run per vault per hour.
- **Blob names repeat, so upload refreshes old blobs:** a name is an image id or a record content hash, so an old unused blob can be needed again. `upload-urls` self-copies (server side, nothing uploaded) any present blob older than 15 days before reporting it `present`, at most once per blob per 15 days. The client must therefore check existence with `upload-urls`, not `download-urls`.
- **Bucket:** unversioned, scoped by vault prefix, no `ListBucket` for the Lambdas. Same pattern as the export bucket.
- **Large files (phase 3):** files may grow from 5 MB to 25-50 MB later. Phase 3 should stream blobs to temp files rather than hold them in memory, and revisit `FileAttachment.maxBytes`, share-extension memory, multipart/background S3 uploads, and a per-vault quota (ties into subscription pricing).
- **Format:** images are HEIC today. Fine on Apple and Android, but most browsers can't decode it. Decide before sync ships whether to switch the default to JPEG or convert in a future web client (section 13).

## 11. API (`/api/v1`, JSON, schemas in `lib/sync/schemas.ts` mirrored in Swift)

| Route | Purpose |
|---|---|
| `POST /devices/app-attest/challenge`, `POST /devices/app-attest/register` | Single-use challenge, then register the device's App Attest key (attestation). Named after the mechanism; Play Integrity would get sibling routes |
| `POST /accounts/sign-in-with-apple` | App Attest assertion + Apple identity token (nonce = sha256hex of a fresh challenge) → `{userId, vaultId \| null, session}`; first use creates our own `userId` and the `ID#apple#<sub>` row atomically (email stored only if Apple sends one) |
| `POST /sessions/app-attest` | Assertion alone → fresh session (refresh for an already-linked device) |
| `POST /vaults` | Bearer. `{kAuthVerifier}` (base64 SHA-256 of `K_auth`) → 201, or 409 `vault_exists`; adds the calling device as the vault's first `D#` row (subscription check comes later; see 12) |
| `POST /vaults/{id}/invites` | Create a pairing invite (QR fallback) |
| `POST /pair` | Join a vault with an invite or a `K_auth` proof |
| `GET/DELETE /vaults/{id}/devices[/{keyId}]` | List or remove devices |
| `POST /push` | `{epoch, records:[{key, baseSeq, deleted, payload}]}` → `{headSeq, seqs}`, 409 `{error:"conflict", conflicts}` (a record moved), or 409 `{error:"epoch_changed", epochChanged:true, epoch}` (the vault's epoch isn't `epoch`; nothing written). 413 `too_large` for more than 99 records, more than 2 MB of payload, or a payload over 64 KiB sealed (checked after the epoch). Duplicate keys are 400. |
| `GET /pull?since=&limit=500` | → `{records, nextSeq, headSeq, more, epoch}`; `limit` defaults to 500 and is capped there, and a page is bounded to about 4 MB of encoded JSON (Lambda's 6 MB response cap). Pull never refuses for staleness. `headSeq` is h, the head read before the query (guarantee 1). `nextSeq` is the last record's seq when `more`, otherwise h. The client's cursor becomes `nextSeq`, never `headSeq`, and `more` with a `nextSeq` that hasn't moved is an error. |
| `GET /head` | `{headSeq, epoch}`, a cheap poll |
| `POST /blobs/upload-urls`, `/blobs/download-urls` | Image transfer (upload reserves quota and refreshes old blobs) |
| `POST /blobs/garbage-collection/live-list-url`, `POST /blobs/garbage-collection` | Presigned PUT for the live list; start a run. Errors: 409 `epoch_changed`, 409 `live_list_missing`, 400 bad size, 409 `garbage_collection_stale` (head moved past `asOfSeq`), 429 `garbage_collection_rate_limited`, 503 `busy` (worker invoke failed; retry) |
| `POST /entitlement` | Signed App Store transaction from the device → verified and stored on the account |
| `DELETE /account` | Delete the account, vault, records and blobs ("Delete sync data"; also "Erase on all devices") |
| `POST /appstore/notifications` | App Store Server Notifications v2 |

- **Wire conventions (built in 2a):** every body carries `serverTime` (ms). Statuses: 400 `bad_request`, 401 `unauthorized`, 404, 413 `too_large`, 503 `busy` (a `HEAD` read cancelled by an in-flight push; retry).
- **Large records:** a record over 64 KiB (the `TRP1` pointer path) is refused with 413 until phase 3 adds the blob bucket.
- **Dev routes:** `POST /dev/vaults` and `POST /dev/vaults/{id}/erase`, behind an `Authorization: Dev <secret>` + `x-tr-vault` bypass with the secret in SSM. The bypass is dev only. Real auth is on where `realAuthEnabled` is set (dev yes, prod no); prod answers 401 to everything until it is flipped. Prod accepts only production App Attest keys; dev also accepts development keys (Xcode builds).
- **No pruning:** tombstones stay forever (see section 9).
- **Session tokens:** HMAC, about 1 hour, bound to `userId`, `keyId` and `vaultId`. Every sync route takes it as `Authorization: Bearer`, and the vault comes only from the token. Each vault request also reads the device's `D#` row, so removing a device takes effect on its next request, not at token expiry. A second device on an account gets a vaultless token until 4b's pairing. `identity_token_invalid` is retryable with a fresh challenge.
- **Limits:** per-route throttles, payload size caps, a storage quota of 10 GiB per vault (built in 3c: `upload-urls` reserves declared sizes and refuses with 413 `quota_exceeded {usedBytes, limitBytes}`; the counter may overcount until the next garbage collection run, never undercounts, and resets on epoch change), and the same status-code vocabulary as the export link.

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
  - Transaction ordering, CAS conflicts, the `HEAD`-bounded pull (guarantee 1).
  - Pairing (single use, expiry) and `K_auth` joins.
  - Sign in with Apple token verification, entitlement JWS verification.
  - Quota, entitlement checks, account deletion.
  - A CDK assertion that the dev auth bypass is missing from prod.
- **Local server (2a):** `pnpm --filter infra sync:local` (in `thoughtreps-aws`) runs the same handlers on 127.0.0.1:8787 against DynamoDB Local 3.3.2 (Java, no Docker). `pnpm --filter infra test:integ` runs 13 integration tests there, including 4 concurrent pushers with a puller. `pnpm test` (113 tests) doesn't need Java. Swift contract tests (2b) run against both the fake and this server, and `scripts/sync-integ.sh` (2c) drives two simulators against it (deleted-while-open on detail, editor and a covered detail; each ends with the Sync lab checks passing on both).
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
| 1 | **Sync engine, no network** (split into rounds 1a, 1b, 1c; **1a done 2026-10-14**: `sync.sqlite`, outbox and hooks, record codec and crypto, `SyncReconciler`; **1b done 2026-10-14**: engine, fake server, `applyRemote`, skew clock, deletions, 409, first-sync paging, in-memory image store; review fixes and the large-record blob path also done; **1c done 2026-10-15**: `ContentMerge`, conflict copies, `attempts` bases, convergence tests; **phase 1 complete**) | `ThoughtReps/Sync/`: `sync.sqlite` (cursor, outbox, base content), outbox hooks in every `ThoughtStore` writer, `applyRemote` sharing `performImport`'s merge, `ContentMerge` (3-way merge, section 8a), conflict copies, the skew-safe clock, `SyncReconciler`, first-sync paging. All against an in-process fake server implementing the push/pull/CAS contract. | Convergence tests pass (N stores, concurrent edits, dropped responses, save failures, clock skew); merge table and property tests pass; IntegrityChecker and SearchIndexChecker stay clean | 3 weeks |
| 2 | **Server, dev stage, text only** (split into rounds; **2a done 2026-10-15**: server, jest, local runner; not deployed, waiting on the AWS accounts. **2b done 2026-10-15**: the Swift HTTP transport, contract tests against both the fake and the local server, `serverTime` offset correction. **2c**: `scripts/sync-integ.sh` with two simulators against the local server (scenarios: the deleted-while-open screens) and a basic DEBUG Sync lab screen **done 2026-10-15**; the dev deploy is pending the accounts) | `ThoughtReps-dev-Sync` (in `thoughtreps-aws`): DynamoDB table with the `bySeq` LSI, push (transaction + CAS), pull, `/head`, the test-only auth bypass. | Two simulators sync text against dev; jest covers ordering, CAS conflicts; a CDK test proves the bypass isn't in prod | 1.5 weeks |
| 3 | **Images** | Blob bucket, presigned upload and download, HMAC blob names, accepting `TRP1` large records (the server refuses them with 413 until then), background `URLSession`, blob-before-record ordering, blob garbage collection and a per-vault quota (**3c done server-side 2026-10-16**; client side pending as round 3d); thoughts held as `Status.waitingForBlobs` in 2b (images, files, records over 64 KiB) keep their meta waiting too, so release both together | Images sync both ways, upload once, and are never missing on the receiving side | 1 week |
| 4 | **Identity and keys** (**4a done server-side 2026-10-16, not deployed**: App Attest, Sign in with Apple, sessions, `POST /vaults`; **4b**: invites, `/pair` by invite or `K_auth` proof, device list and removal, `DELETE /account`, erase on all devices; **4c**: the Swift client, which needs a real device for App Attest) | Sign in with Apple (or vault creation under A), App Attest sessions, Keychain key (synced and local items, section 5), QR pairing that also links the account, recovery code, `K_auth` join, device list and removal, erase choices, "Delete sync data". The "Needs a look" timeline section and resolve sheet. Prod stack deployed. | A real iPhone and iPad pair, join and recover; the full Sync lab runs on both | 2 weeks |
| 5 | **Subscription** | StoreKit 2 subscription, `appAccountToken`, `/entitlement` JWS check, App Store Server Notifications v2, deleting data 30 days after a lapse, restore purchases | Sandbox subscribe, renew, lapse and restore all behave correctly | 1 week |
| 6 | **Launch prep** | Privacy manifests, `privacy.ts`, App Store privacy answers, help article (including conflict copies), `INTEGRATIONS.md`, CLAUDE.md network rule, App Review items, TestFlight with real device pairs | Testers sync real libraries for a week with no divergence | 1 week + beta |

**Decisions needed before each phase:**

- **Before 0 and 1:** none.
- **Before 3:** HEIC or JPEG as the image default.
- **Before 4:** account (B) or no account (A). The only decision that changes code.
- **Before 5:** subscription add-on or included, and the price.
- **Before 6:** nothing on the wire format: padding to size buckets, the key-generation byte and the frame layouts are settled (section 4).

**Later, not in v1:** bootstrap snapshot for very large libraries, key rotation (real device revocation), server escrow, Android (section 13).

## Open decisions

1. ~~**Account when sync is turned on (B, Sign in with Apple) or no account (A)?**~~ Decided 2026-10-16: B, with sign-ins mapped to our own `userId` and QR-only join kept (section 2).
2. **Subscription add-on, or included?** Recommended: an add-on, so the paid-once app stays whole.
3. **Reminders per device, off by default on new devices?** Recommended: yes.
4. **iCloud Keychain key storage defaulted on?** Recommended: yes, with an explanation.
5. ~~**Pad record sizes to buckets?**~~ Decided: yes, power-of-two buckets from 512 B to 1 MiB, then whole MiB (section 4).
6. **HEIC or JPEG as the image default** before phase 3 (matters for a future web client).
7. **Server escrow:** not in v1; add only if people ask, as a separate opt-in.

Decided on 2026-10-15: the server keeps deletion tombstones forever (no prune, 410 or resync; see section 9). Decided on 2026-10-14: 3-way merge in v1 with conflict copies as the fallback, marked by `conflictOfID` (section 8a). The iPad app has shipped.
