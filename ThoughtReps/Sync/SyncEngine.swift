import Foundation
import os

/// One device's side of the sync protocol: a cycle pulls (paging until caught up), downloads the blobs the
/// pulled content needs, applies the page through the store, then pushes the outbox. See the sync spec,
/// sections 7 to 10.
///
/// - A pulled page is applied first and only then are its cursor and record bases committed (one SQLite
///   transaction), so a failed apply leaves the cursor where it was and the next cycle retries.
/// - Every outbox entry is pushed unless its plaintext hash equals the base hash: that is also how a write
///   whose response was lost is recognized (the pull brings it back as the base).
/// - A 409 means a record moved: pull, apply, and push again with the new bases, a few times at most.
/// - The server keeps deletion tombstones forever, so a pull from any cursor is complete. A 410 is a refusal like any other.
/// - A changed epoch (the vault was erased elsewhere), seen by a pull or refused by a push, stops syncing and shows up as
///   `Status.attention`. Nothing is uploaded again until the user decides what to do with this device's copy.
/// - A pulled page moves the cursor to the page's `nextSeq`, never to the server's head, which a push can pass between the
///   page's query and the head read.
actor SyncEngine {
    struct Configuration: Sendable {
        var pullLimit = 200
        /// Outbox entities per push batch. A thought is two records, so 49 fit in the transport's 99.
        var pushEntities = 49
        var maxConflictRetries = 5
        var maxRecordsPerPush = SyncLimits.maxRecordsPerPush
        var maxBytesPerPush = SyncLimits.maxBytesPerPush
        /// A sealed record over this goes up as a blob and the row holds a pointer to it.
        var maxInlinePayload = SyncLimits.maxInlinePayload
        /// A sealed record over this is never pushed: its thought is held back and counted in `Status.oversizedThoughts`.
        var maxRecordBytes = SyncLimits.maxRecordBytes
        /// Plaintext and blob bytes planned in memory before a push chunk is sent; one bigger entity goes alone.
        var maxPlanBytes = SyncLimits.maxPlanBytes
        var blobsPerRead = 8
        var maxApplyBytes = SyncLimits.maxApplyBytes
        var maxAssetBlobBytes = SyncLimits.maxAssetBlobBytes
        /// A library with more images and files than this skips garbage collection.
        var maxLiveListNames = SyncLimits.maxLiveListNames
        /// The newest payload version this build reads; records past it are parked until the app is updated.
        var payloadVersion = SyncPayload.currentVersion
        /// What this build can read, as one number: parked records are tried again when it changes, so it must be bumped
        /// whenever the app learns to read something new (a payload version, a key generation, a frame magic).
        var readerVersion = SyncCrypto.readerVersion
        /// The newest key generation this build can open.
        var keyGeneration = SyncCrypto.currentKeyGeneration
    }

    enum Phase: Sendable, Equatable {
        case idle, pulling, pushing, stopped
    }

    enum Attention: Sendable, Equatable {
        /// The vault was erased on another device (or replaced). Syncing stops, because pushing on would bring back what was
        /// erased, until the user decides what to do with this device's copy.
        case epochChanged(known: Int64, server: Int64)
        /// The server refused a request outright (bad request, unauthorized, unknown vault). Retrying can't help, so syncing
        /// stops until the app is relaunched.
        case serverRefused(status: Int, message: String)
    }

    struct Status: Sendable, Equatable {
        var phase: Phase = .idle
        /// Outbox entries left; during a first sync, how much is still to upload.
        var pending = 0
        var lastError: String?
        var attention: Attention?
        var cursor: Int64 = 0
        /// The server head this device last pulled up to; nil until a pull has caught up. Not moved by a pull that is cut
        /// short, so the head check keeps seeing the difference and finishes it.
        var headSeq: Int64?
        var cycles = 0
        /// Some records are from a newer version of the app and wait, still sealed, until it is updated. Syncing goes on.
        var updateRequired = false
        /// Thoughts held back because a blob is missing or their images belong to another thought; retried every cycle.
        var blockedThoughts = 0
        /// Queued local changes not pushed because the server's version of that thought is parked, blocked or held:
        /// they go out once it has been applied and merged.
        var waitingThoughts = 0
        /// Queued thoughts too big to sync (a sealed record over `maxRecordBytes`, or one the server refused as too large),
        /// They stay queued, and everything else still goes out.
        var oversizedThoughts = 0
        /// Queued thoughts whose image or file bytes are missing on this device. Only they wait (the server must not be
        /// told the attachment is gone); retried every cycle.
        var missingAttachments = 0
        /// Queued thoughts that need blob storage the server lacks (`SyncTransport.supportsBlobs`): an image, a file, or a
        /// record over `maxInlinePayload`. The whole thought waits, so its meta changes (pin, archive, snooze) wait with
        /// it until the transport has blobs. Retried every cycle, without a request.
        var waitingForBlobs = 0
        /// Queued thoughts whose blobs the server refused because the vault is over its storage limit. Retried every cycle, so
        /// they go out once space is freed; everything else still syncs.
        var quotaExceededThoughts = 0
        /// The usage the server last reported with a refusal; nil while no thought is held for it.
        var blobQuota: BlobQuota?
    }

    struct BlobQuota: Sendable, Equatable {
        var usedBytes: Int64
        var limitBytes: Int64
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case applyFailed
        case tooManyConflicts
        case invalidRecord(String)
        case missingSeq(String)
        case blobUnreadable(String)
        case blobsMissing([String])
        case pullStalled(Int64)
        case missingEpoch

        var description: String {
            switch self {
            case .applyFailed: "applying remote changes failed"
            case .tooManyConflicts: "too many conflicts"
            case .invalidRecord(let key): "record \(key) is not valid"
            case .missingSeq(let key): "no seq for \(key)"
            case .blobUnreadable(let name): "blob \(name) is not readable"
            case .blobsMissing(let names): "the server lacks blobs \(names.joined(separator: ", ")) after they were uploaded"
            case .pullStalled(let cursor): "the server has more records but none after seq \(cursor)"
            case .missingEpoch: "no epoch known to push with"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "sync")

    private let transport: SyncTransport
    private let state: SyncState
    private let local: SyncLocalStore
    private let keys: SyncKeys
    private let vaultID: String
    private let codec: SyncBlobCodec
    private let config: Configuration
    private let clockNow: @Sendable () -> Date

    private(set) var status = Status()
    private var observer: (@Sendable (Status) -> Void)?
    private var running: Task<Void, Never>?
    private var rerun = false
    private var isShutDown = false
    private var cycleNumber = 0
    /// Queued thoughts left alone in this push because the server holds a version this device couldn't apply yet.
    private var waitingEntities: Set<SyncEntity> = []
    private var oversizedEntities: Set<SyncEntity> = []
    private var blobHeldEntities: Set<SyncEntity> = []
    private var missingAttachmentEntities: Set<SyncEntity> = []
    private var quotaHeldEntities: Set<SyncEntity> = []
    private var lastQuota: BlobQuota?
    /// Set once a hold for the storage limit has asked for a run, until no thought is held: a hold that outlasts the run
    /// waits for the next week's run instead of asking every cycle. Kept in memory.
    private var quotaHitNoted = false
    /// Record keys whose record was over `maxRecordBytes`, with the fingerprint it had then: skipped (not encoded and
    /// sealed again) until the fingerprint changes. Kept in memory.
    private var oversizedFingerprints: [String: String] = [:]
    /// What the tests read to check the memory budgets: the most bytes planned for one push chunk, resolved for one pull
    /// sub-batch, and how many records were sealed.
    private(set) var peakPlannedBytes = 0
    private(set) var peakResolvedBytes = 0
    private(set) var recordsSealed = 0
    /// Held thoughts with a blob that is there but can't be read: retried after 2, 4, 8 … (at most 32) cycles instead of
    /// every one, since each try downloads it again. Kept in memory, so a relaunch tries them all.
    private var unreadableBackoff: [String: (attempts: Int, retryAt: Int)] = [:]

    init(
        transport: SyncTransport, state: SyncState, local: SyncLocalStore, keys: SyncKeys, vaultID: String,
        codec: SyncBlobCodec = .live, config: Configuration = Configuration(), now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.clockNow = now
        self.transport = transport
        self.state = state
        self.local = local
        self.keys = keys
        self.vaultID = vaultID
        self.codec = codec
        self.config = config
    }

    func setObserver(_ observer: (@Sendable (Status) -> Void)?) {
        self.observer = observer
    }

    // MARK: Running

    /// Runs a cycle, or asks the one in progress to run once more when it finishes, and returns when that is done.
    @discardableResult
    func syncNow() async -> Status {
        guard !isShutDown else { return status }
        if let running {
            rerun = true
            await running.value
            return status
        }
        let task = Task { await self.cycles() }
        running = task
        await task.value
        return status
    }

    /// Ends the engine for good. It awaits the running cycle, so nothing of this engine runs after it returns; the cycle's
    /// checks before each apply and state write only make it exit early.
    func stop() async {
        isShutDown = true
        let task = running
        task?.cancel()
        await task?.value
    }

    private func checkActive() throws {
        if isShutDown || Task.isCancelled { throw CancellationError() }
    }

    private func commitPage(_ page: PageCommit) async throws {
        try checkActive()
        try await state.commit(page)
    }

    /// The periodic check: asks the server for its head and runs a cycle if it moved past what was pulled, if the last cycle
    /// failed (so an interrupted pull is resumed), or if the outbox holds something a push could send. Entries held back
    /// (waiting, oversized, missing attachments) don't count: they only change when a pull or a local write does.
    @discardableResult
    func syncIfHeadMoved() async -> Bool {
        guard status.attention == nil else { return false }
        do {
            let head = try await transport.head()
            if let known = try await state.epoch(), known != head.epoch {
                stop(.epochChanged(known: known, server: head.epoch))
                return false
            }
            let heldBack = waitingEntities.union(oversizedEntities).union(missingAttachmentEntities).union(blobHeldEntities).union(quotaHeldEntities).count
            let hasPushable = try await state.outboxCount() > heldBack
            guard head.headSeq != status.headSeq || status.lastError != nil || hasPushable else { return false }
        } catch SyncTransportError.refused(let status, let message) {
            stop(.serverRefused(status: status, message: message))
            return false
        } catch {
            record(error)
            return false
        }
        await syncNow()
        return true
    }

    private func cycles() async {
        repeat {
            rerun = false
            cycleNumber += 1
            guard status.attention == nil else { break }
            do {
                update { $0.phase = .pulling }
                try await reapplyParked()
                try await retryPointers()
                try await retryBlocked()
                try await pull()
                update { $0.phase = .pushing }
                try await push()
                update {
                    $0.phase = .idle
                    $0.lastError = nil
                    $0.cycles += 1
                }
                await collectGarbageIfDue()
            } catch let failure as AttentionFailure {
                stop(failure.attention)
            } catch SyncTransportError.refused(let status, let message) {
                stop(.serverRefused(status: status, message: message))
            } catch {
                if isShutDown {
                    update { $0.phase = .stopped }
                } else {
                    record(error)
                }
            }
            if !isShutDown { await refreshPending() }
        } while rerun && status.lastError == nil && status.attention == nil && !isShutDown
        running = nil
    }

    private struct AttentionFailure: Error {
        var attention: Attention
    }

    private func stop(_ attention: Attention) {
        guard !isShutDown else { return }
        Self.logger.error("Sync stopped: \(String(describing: attention))")
        update {
            $0.phase = .stopped
            $0.attention = attention
        }
    }

    private func record(_ error: Error) {
        Self.logger.error("Sync cycle failed: \(error)")
        update {
            $0.phase = .idle
            $0.lastError = "\(error)"
        }
    }

    private func update(_ change: (inout Status) -> Void) {
        change(&status)
        observer?(status)
    }

    private func refreshPending() async {
        let count = (try? await state.outboxCount()) ?? status.pending
        let cursor = (try? await state.cursor()) ?? status.cursor
        let pointers = (try? await state.parkedPointerCount()) ?? 0
        let parked = ((try? await state.parkedCount()) ?? 0) - pointers
        let blocked = ((try? await state.blockedEntityIDs().count) ?? status.blockedThoughts) + pointers
        update {
            $0.pending = count
            $0.cursor = cursor
            $0.updateRequired = parked > 0
            $0.blockedThoughts = blocked
        }
    }

    // MARK: Pull

    private struct Decoded {
        var record: PulledRecord
        var payload: SyncPayload
        var plaintext: Data
        var hash: String
    }

    private enum Reading {
        case readable(Decoded)
        case parked(ParkedRecord)
    }

    /// A record this version can't interpret (a newer payload version or key generation, an unknown type or frame magic) is
    /// parked, not an error. One that fails to decrypt is: it was damaged or tampered with, and the cycle stops.
    private func read(_ record: PulledRecord) throws -> Reading {
        let parked = Reading.parked(ParkedRecord(recordKey: record.recordKey, seq: record.seq, payload: record.payload, deleted: record.deleted))
        let opened: SyncCrypto.Opened
        do {
            opened = try SyncCrypto.open(
                record.payload, vaultID: vaultID, recordKey: record.recordKey, keys: keys, readableKeyGeneration: config.keyGeneration
            )
        } catch SyncCrypto.Failure.unrecognizedMagic, SyncCrypto.Failure.unsupportedKeyGeneration(_) {
            return parked
        }
        guard opened.payloadVersion <= config.payloadVersion else { return parked }
        let payload: SyncPayload
        do {
            payload = try SyncPayload.decode(opened.plaintext, supporting: config.payloadVersion)
        } catch SyncPayload.Failure.unsupportedVersion(_), SyncPayload.Failure.unknownType(_) {
            return parked
        }
        guard keys.recordKey(type: payload.type, entityID: payload.entityID) == record.recordKey,
              payload.isDeletion == record.deleted
        else { throw Failure.invalidRecord(record.recordKey) }
        return .readable(Decoded(record: record, payload: payload, plaintext: opened.plaintext, hash: SyncPayload.hash(of: opened.plaintext)))
    }

    /// Pulls until caught up.
    private func pull() async throws {
        // A `sync.sqlite` rebuilt mid-session has lost its outbox, so whatever isn't synced is queued again.
        if try await state.cursor() == 0 { await local.reconcile() }
        while true {
            let cursor = try await state.cursor()
            try checkActive()
            let page = try await transport.pull(after: cursor, limit: config.pullLimit)
            try checkActive()
            guard !page.hasMore || page.nextSeq > cursor else { throw Failure.pullStalled(cursor) }
            try await apply(page, after: cursor)
            if !page.hasMore {
                update { $0.headSeq = max(cursor, page.nextSeq) }
                return
            }
        }
    }

    private func apply(_ page: PullPage, after cursor: Int64) async throws {
        if let known = try await state.epoch(), known != page.epoch {
            throw AttentionFailure(attention: .epochChanged(known: known, server: page.epoch))
        }
        let finalCursor = max(cursor, page.nextSeq)
        var decoded: [Decoded] = []
        var parks: [ParkedRecord] = []
        var bytes = 0
        for record in page.records {
            let resolved: PulledRecord
            switch try await resolvePointer(record, epoch: page.epoch) {
            case .waiting:
                parks.append(Self.parked(record))
                continue
            case .updateRequired:
                parks.append(Self.parked(record, needsUpdate: true))
                continue
            case .record(let found):
                resolved = found
            }
            let size = resolved.payload.count
            // Earlier sub-batches leave the cursor where it was: if the page fails midway it is fetched again, and what
            // was applied is skipped by its base hash.
            if !decoded.isEmpty, bytes + size > config.maxApplyBytes {
                try await applyBatch(decoded, park: parks, cursor: cursor, epoch: page.epoch)
                decoded = []
                parks = []
                bytes = 0
            }
            let reading: Reading
            do {
                reading = try read(resolved)
            } catch let failure as SyncCrypto.Failure
                where (failure == .decryptionFailed || failure == .badFormat) && SyncCrypto.blobName(inPointer: record.payload) != nil {
                // The blob opened but doesn't hold this record (a pointer aimed at another record's blob, or not a record
                // frame at all). Only this thought waits, like any other unreadable blob.
                backOff(record.recordKey)
                parks.append(Self.parked(record))
                continue
            }
            switch reading {
            case .readable(let item):
                decoded.append(item)
                bytes += size
                peakResolvedBytes = max(peakResolvedBytes, bytes)
            case .parked(let parked): parks.append(parked)
            }
        }
        try await applyBatch(decoded, park: parks, cursor: finalCursor, epoch: page.epoch)
    }

    private static func parked(_ record: PulledRecord, needsUpdate: Bool = false) -> ParkedRecord {
        ParkedRecord(recordKey: record.recordKey, seq: record.seq, payload: record.payload, deleted: record.deleted, needsUpdate: needsUpdate)
    }

    private func applyBatch(_ decoded: [Decoded], park: [ParkedRecord], cursor: Int64, epoch: Int64) async throws {
        var commit = PageCommit(cursor: cursor, epoch: epoch)
        commit.park = park
        commit.unpark = decoded.map(\.record.recordKey)
        try await process(decoded, retrying: [], commit: &commit)
    }

    private enum Resolution {
        /// The record itself, or the record a pointer pointed to.
        case record(PulledRecord)
        /// The blob isn't there or can't be read yet.
        case waiting
        /// The blob is in a frame from a newer version of the app.
        case updateRequired
    }

    /// A pointer record becomes the record it points to. When the blob isn't there or can't be read yet, the pointer
    /// stays parked (a missing blob is tried every cycle, an unreadable one after 2, 4, 8 … cycles) and only that thought
    /// waits. A blob from a newer app parks it until this one is updated.
    private func resolvePointer(_ record: PulledRecord, epoch: Int64) async throws -> Resolution {
        guard let name = SyncCrypto.blobName(inPointer: record.payload) else { return .record(record) }
        if let backoff = unreadableBackoff[record.recordKey], backoff.retryAt > cycleNumber { return .waiting }
        do {
            let sealed = try await transport.getBlob(name: name, epoch: epoch, maxBytes: config.maxRecordBytes + SyncCrypto.blobOverheadBytes)
            var resolved = record
            resolved.payload = try SyncCrypto.openBlob(sealed, vaultID: vaultID, name: name, keys: keys)
            unreadableBackoff[record.recordKey] = nil
            return .record(resolved)
        } catch SyncTransportError.blobMissing(_) {
            unreadableBackoff[record.recordKey] = nil
            return .waiting
        } catch SyncTransportError.unsupported {
            return .waiting
        } catch SyncTransportError.epochChanged(let server) {
            throw AttentionFailure(attention: .epochChanged(known: epoch, server: server))
        } catch SyncTransportError.tooLarge {
            backOff(record.recordKey)
            return .waiting
        } catch SyncCrypto.Failure.unrecognizedMagic, SyncCrypto.Failure.unsupportedKeyGeneration(_) {
            unreadableBackoff[record.recordKey] = nil
            return .updateRequired
        } catch is SyncCrypto.Failure {
            backOff(record.recordKey)
            return .waiting
        }
    }

    private func backOff(_ key: String) {
        let attempts = (unreadableBackoff[key]?.attempts ?? 0) + 1
        unreadableBackoff[key] = (attempts, cycleNumber + min(1 << attempts, 32))
    }

    /// Pointer records parked for a blob that wasn't there are tried again before anything new.
    private func retryPointers() async throws {
        let pointers = try await state.parkedPointers()
        guard !pointers.isEmpty, let epoch = try await state.epoch() else { return }
        let bases = try await state.records(forKeys: pointers.map(\.recordKey), includingContent: false)
        for record in pointers {
            do {
                let pulled = PulledRecord(recordKey: record.recordKey, seq: record.seq, payload: record.payload, deleted: record.deleted)
                var commit = PageCommit(cursor: try await state.cursor(), epoch: epoch)
                let resolved: PulledRecord
                switch try await resolvePointer(pulled, epoch: epoch) {
                case .waiting:
                    continue
                case .updateRequired:
                    commit.park = [Self.parked(pulled, needsUpdate: true)]
                    try await commitPage(commit)
                    continue
                case .record(let found):
                    resolved = found
                }
                let reading: Reading
                do {
                    reading = try read(resolved)
                } catch {
                    backOff(record.recordKey)
                    throw error
                }
                switch reading {
                case .parked(let parked):
                    commit.park = [parked]
                    try await commitPage(commit)
                case .readable(let item):
                    commit.unpark = [record.recordKey]
                    let superseded = bases[record.recordKey].map { $0.seq >= record.seq } ?? false
                    try await process(superseded ? [] : [item], retrying: [], commit: &commit)
                }
            } catch {
                Self.logger.error("Pointer record \(record.recordKey) not applied this cycle: \(error)")
            }
        }
    }

    /// Parked records this version can read now (it was updated) are applied before anything new. Whether one is readable
    /// depends only on what this build can read (`readerVersion`), so they are tried again only when it differs from the last try, and that is
    /// noted only once every record that could be read has been applied.
    private func reapplyParked() async throws {
        guard try await state.parkedVersionTried() != config.readerVersion else { return }
        guard let epoch = try await state.epoch() else {
            try await state.setParkedVersionTried(config.readerVersion)
            return
        }
        var allApplied = true
        var after: (seq: Int64, key: String)?
        while true {
            let page = try await state.parked(after: after, limit: Self.parkedPageSize)
            guard let last = page.last else { break }
            after = (last.seq, last.recordKey)
            let bases = try await state.records(forKeys: page.map(\.recordKey), includingContent: false)
            for record in page {
                // One record that won't apply is logged and stays parked; it must not stop the rest of the cycle.
                do {
                    try await reapply(record, epoch: epoch, supersededBy: bases[record.recordKey]?.seq)
                } catch {
                    allApplied = false
                    Self.logger.error("Parked record \(record.recordKey) not applied this cycle: \(error)")
                }
            }
        }
        if allApplied { try await state.setParkedVersionTried(config.readerVersion) }
    }

    private static let parkedPageSize = 8

    private func reapply(_ record: ParkedRecord, epoch: Int64, supersededBy syncedSeq: Int64?) async throws {
        let pulled = PulledRecord(recordKey: record.recordKey, seq: record.seq, payload: record.payload, deleted: record.deleted)
        var resolved = pulled
        if SyncCrypto.blobName(inPointer: record.payload) != nil {
            switch try await resolvePointer(pulled, epoch: epoch) {
            case .updateRequired:
                return
            case .waiting:
                var commit = PageCommit(cursor: try await state.cursor(), epoch: epoch)
                commit.park = [Self.parked(pulled)]
                try await commitPage(commit)
                return
            case .record(let found):
                resolved = found
            }
        }
        let reading: Reading
        do {
            reading = try read(resolved)
        } catch {
            Self.logger.error("Parked record \(record.recordKey) is not readable: \(error)")
            return
        }
        guard case .readable(let item) = reading else { return }
        var commit = PageCommit(cursor: try await state.cursor(), epoch: epoch)
        commit.unpark = [record.recordKey]
        let superseded = syncedSeq.map { $0 >= record.seq } ?? false
        try await process(superseded ? [] : [item], retrying: [], commit: &commit)
    }

    /// Held thoughts whose blobs were missing, or whose images clashed, are tried again every cycle.
    private func retryBlocked() async throws {
        let ids = try await state.blockedEntityIDs()
        guard !ids.isEmpty, let epoch = try await state.epoch() else { return }
        for id in ids {
            if let backoff = unreadableBackoff[id], backoff.retryAt > cycleNumber { continue }
            // One thought that won't apply is logged and stays held; it must not stop the rest of the cycle.
            do {
                var commit = PageCommit(cursor: try await state.cursor(), epoch: epoch)
                try await process([], retrying: [id], commit: &commit)
            } catch {
                Self.logger.error("Held thought \(id) not applied this cycle: \(error)")
            }
        }
    }

    private struct BlobFailure: Error {
        /// The blob exists but can't be decrypted or decoded (as opposed to not being on the server).
        var unreadable: Bool
    }

    private struct Applying {
        var pending: [RemoteThought] = []
        var bytes = 0
        var outcome = RemoteOutcome()
    }

    private func flush(_ work: inout Applying, tags: [TagRecord] = [], settings: SettingsRecord? = nil) async throws {
        let next = RemoteBatch(thoughts: work.pending, tags: tags, settings: settings)
        work.pending = []
        work.bytes = 0
        guard !next.thoughts.isEmpty || !next.tags.isEmpty || next.settings != nil else { return }
        try checkActive()
        work.outcome.merge(await local.apply(next, now: clockNow()))
        guard work.outcome.saved else { throw Failure.applyFailed }
    }

    /// Applies the records (and the held ones of `retrying`) and commits the result with `commit`'s cursor, epoch and
    /// parked records. The store applies in sub-batches of at most `maxApplyBytes` of downloaded image and file bytes.
    private func process(_ decoded: [Decoded], retrying: [String], commit: inout PageCommit) async throws {
        let bases = try await state.records(forKeys: decoded.map(\.record.recordKey))
        var fresh: [Decoded] = []
        for item in decoded {
            if let base = bases[item.record.recordKey], base.baseHash == item.hash {
                if base.seq != item.record.seq {
                    var moved = base
                    moved.seq = item.record.seq
                    commit.records.append(moved)
                }
            } else {
                fresh.append(item)
            }
        }

        var batch = RemoteBatch()
        var thoughtIDs: [String] = []
        var freshByThought: [String: [Decoded]] = [:]
        for item in fresh {
            switch item.payload {
            case .tag(let tag): batch.tags.append(tag)
            case .settings(let settings): batch.settings = settings
            case .thoughtContent, .thoughtMeta, .deletion:
                if freshByThought[item.payload.entityID] == nil { thoughtIDs.append(item.payload.entityID) }
                freshByThought[item.payload.entityID, default: []].append(item)
            }
        }
        for id in retrying where freshByThought[id] == nil && !thoughtIDs.contains(id) { thoughtIDs.append(id) }

        let held = Dictionary(grouping: try await state.held(entityIDs: thoughtIDs), by: \.entityID)
        let lastSynced = try await state.records(forKeys: thoughtIDs.flatMap { id in
            [keys.recordKey(type: .thoughtContent, entityID: id), keys.recordKey(type: .thoughtMeta, entityID: id)]
        })
        let attempts = try await state.attempts(forKeys: thoughtIDs.map { keys.recordKey(type: .thoughtContent, entityID: $0) })
        var thoughts: [RemoteThought] = []
        for idString in thoughtIDs {
            guard let id = UUID(uuidString: idString) else { throw Failure.invalidRecord(idString) }
            var remote = RemoteThought(id: id)
            for held in held[idString] ?? [] {
                switch try SyncPayload.decode(held.payload, supporting: config.payloadVersion) {
                case .thoughtContent(let content): remote.content = content
                case .thoughtMeta(let meta): remote.meta = meta
                default: break
                }
            }
            for item in freshByThought[idString] ?? [] {
                switch item.payload {
                case .thoughtContent(let content): remote.content = content
                case .thoughtMeta(let meta): remote.meta = meta
                case .deletion(_, let deletion):
                    if remote.deletion.map({ $0.deletedAt < deletion.deletedAt }) ?? true { remote.deletion = deletion }
                default: break
                }
            }
            let contentKey = keys.recordKey(type: .thoughtContent, entityID: idString)
            if let base = lastSynced[contentKey] {
                remote.contentBaseHash = base.baseHash
                if case .thoughtContent(let content)? = try? SyncPayload.decode(base.baseContent, supporting: config.payloadVersion) { remote.contentBase = content }
            } else if let attempt = attempts[contentKey] {
                remote.contentBaseHash = attempt.hash
                if case .thoughtContent(let content)? = try? SyncPayload.decode(attempt.plaintext, supporting: config.payloadVersion) { remote.contentBase = content }
            }
            if let base = lastSynced[keys.recordKey(type: .thoughtMeta, entityID: idString)],
               case .thoughtMeta(let meta)? = try? SyncPayload.decode(base.baseContent, supporting: config.payloadVersion) {
                remote.metaBase = meta
            }
            thoughts.append(remote)
        }

        let missing = try await local.missingBlobs(for: thoughts.compactMap(\.content))
        var work = Applying()
        var blocked = Set<UUID>()
        var appliedTags: [UUID: [SyncEntity]] = [:]
        var committed = Set<UUID>()

        func settle(_ ids: Set<UUID>, _ outcome: RemoteOutcome, isFinal: Bool, into commit: inout PageCommit) {
            let unsettled = blocked.union(outcome.rejected)
            var freshKeys = Set<String>()
            for item in fresh {
                let entityID = item.payload.entityID
                let id = freshByThought[entityID] != nil ? UUID(uuidString: entityID) : nil
                if let id { guard ids.contains(id) else { continue } } else if !isFinal { continue }
                freshKeys.insert(item.record.recordKey)
                let isBlocked = id.map(unsettled.contains) ?? false
                if isBlocked || (id.map(outcome.held.contains) ?? false) {
                    commit.hold.append(HeldRecord(
                        recordKey: item.record.recordKey, type: item.payload.type, entityID: entityID, seq: item.record.seq,
                        payload: item.plaintext, blocked: isBlocked
                    ))
                }
                // A blocked record gets no base, so it still counts as not applied and is tried again every cycle.
                if isBlocked {
                    Self.logger.error("Pulled record \(item.record.recordKey) not applied yet: a blob is missing or its images belong to another thought")
                    continue
                }
                commit.records.append(SyncedRecord(
                    recordKey: item.record.recordKey, type: item.payload.type, entityID: entityID, seq: item.record.seq,
                    fingerprint: item.payload.fingerprint, baseHash: item.hash, baseContent: item.plaintext
                ))
            }
            // A thought that was held and has now been applied gets its bases from the held records.
            for (entityID, rows) in held {
                guard let id = UUID(uuidString: entityID), ids.contains(id), !unsettled.contains(id), !outcome.held.contains(id) else { continue }
                for row in rows where !freshKeys.contains(row.recordKey) {
                    guard let payload = try? SyncPayload.decode(row.payload, supporting: config.payloadVersion) else { continue }
                    commit.records.append(SyncedRecord(
                        recordKey: row.recordKey, type: row.type, entityID: entityID, seq: row.seq,
                        fingerprint: payload.fingerprint, baseHash: SyncPayload.hash(of: row.payload), baseContent: row.payload
                    ))
                }
            }
            commit.release += thoughtIDs.filter {
                let id = UUID(uuidString: $0) ?? UUID()
                return ids.contains(id) && !outcome.held.contains(id) && !unsettled.contains(id)
            }
            commit.forgetAttempts += thoughts.filter { ids.contains($0.id) && $0.deletion != nil && !unsettled.contains($0.id) }.map { $0.id.uuidString }
            commit.requeue += Array(outcome.requeue) + appliedTags.filter { ids.contains($0.key) && !unsettled.contains($0.key) }.flatMap(\.value)
        }

        for var thought in thoughts {
            let size: Int
            do {
                size = try await download(into: &thought, missing: missing, epoch: commit.epoch)
            } catch let failure as BlobFailure {
                blocked.insert(thought.id)
                let key = thought.id.uuidString
                if failure.unreadable {
                    backOff(key)
                } else {
                    unreadableBackoff[key] = nil
                }
                continue
            }
            unreadableBackoff[thought.id.uuidString] = nil
            if !work.pending.isEmpty, work.bytes + size > config.maxApplyBytes {
                let flushed = Set(work.pending.map(\.id))
                try await flush(&work)
                // Committed now, cursor unchanged, so a failure in a later sub-batch finds the bases of this one and
                // merges against them again instead of seeing the merged text as a rival edit.
                var partial = PageCommit(cursor: try await state.cursor(), epoch: commit.epoch)
                settle(flushed, work.outcome, isFinal: false, into: &partial)
                try await commitPage(partial)
                committed.formUnion(flushed)
            }
            work.pending.append(thought)
            work.bytes += size
            // Only the tags are kept past the sub-batch, so its downloaded blobs can be released.
            appliedTags[thought.id] = Self.tagEntities(in: thought.content.map { [$0] } ?? [])
        }
        try await flush(&work, tags: batch.tags, settings: batch.settings)
        let outcome = work.outcome

        let remaining = Set(thoughtIDs.compactMap(UUID.init(uuidString:))).subtracting(committed)
        settle(remaining, outcome, isFinal: true, into: &commit)
        try await commitPage(commit)
    }

    /// The tags the pulled bodies use. Applying them may have created a tag here with the display name of
    /// a body, while the server holds another; queued, the push step settles it against the synced record
    /// (and skips it when they agree).
    private static func tagEntities(in contents: [ThoughtContentRecord]) -> [SyncEntity] {
        let texts = contents.flatMap { [$0.body] + $0.blocks.filter { $0.resolved?.kind == .markdown }.map(\.content) }
        return Set(TagParser.parse(all: texts).map(\.key)).map(SyncEntity.tag)
    }

    /// Downloads the blobs of the thought's content that the store lacks and returns their size in memory. A blob that is
    /// missing or can't be read throws `BlobFailure`, which holds just this thought; a network failure ends the cycle.
    private func download(into thought: inout RemoteThought, missing: Set<BlobRef>, epoch: Int64) async throws -> Int {
        guard let content = thought.content, !missing.isEmpty else { return 0 }
        let imageIDs = Set((content.images + content.blocks.flatMap(\.images)).map(\.id))
        let fileRecords = Dictionary(content.blocks.compactMap(\.file).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var size = 0
        for ref in missing {
            let name = keys.blobName(kind: ref.kind, id: ref.id)
            switch ref.kind {
            case .image where imageIDs.contains(ref.id), .file where fileRecords[ref.id] != nil:
                do {
                    let sealed = try await transport.getBlob(name: name, epoch: epoch, maxBytes: config.maxAssetBlobBytes + SyncCrypto.blobOverheadBytes)
                    let bytes = try SyncCrypto.openBlob(sealed, vaultID: vaultID, name: name, keys: keys)
                    if ref.kind == .image {
                        let image = try codec.image(bytes)
                        thought.images[ref.id] = image
                        size += image.data.count + image.thumbnailData.count
                    } else {
                        let file = try codec.file(bytes, fileRecords[ref.id]!)
                        thought.files[ref.id] = file
                        size += bytes.count + (file.thumbnailData?.count ?? 0)
                    }
                } catch SyncTransportError.blobMissing(_), SyncTransportError.unsupported {
                    throw BlobFailure(unreadable: false)
                } catch SyncTransportError.epochChanged(let server) {
                    throw AttentionFailure(attention: .epochChanged(known: epoch, server: server))
                } catch is SyncCrypto.Failure, is ImageProcessingError, is FileProcessingError, SyncTransportError.tooLarge {
                    throw BlobFailure(unreadable: true)
                }
            default:
                continue
            }
        }
        return size
    }

    // MARK: Push

    private enum BatchResult {
        case done
        case conflict
    }

    private func push() async throws {
        var after: SyncEntity?
        var conflicts = 0
        waitingEntities = []
        oversizedEntities = []
        blobHeldEntities = []
        missingAttachmentEntities = []
        quotaHeldEntities = []
        lastQuota = nil
        defer {
            let waiting = waitingEntities.count
            let oversized = oversizedEntities.count
            let missing = missingAttachmentEntities.count
            let blobHeld = blobHeldEntities.count
            let overQuota = quotaHeldEntities.count
            let quota = lastQuota
            update {
                $0.waitingForBlobs = blobHeld
                $0.waitingThoughts = waiting
                $0.oversizedThoughts = oversized
                $0.missingAttachments = missing
                $0.quotaExceededThoughts = overQuota
                $0.blobQuota = overQuota > 0 ? quota : nil
            }
        }
        while true {
            try checkActive()
            let entries = try await state.outbox(limit: config.pushEntities, after: after)
            guard let last = entries.last else { break }
            switch try await pushBatch(entries) {
            case .done:
                after = last.entity
            case .conflict:
                conflicts += 1
                guard conflicts <= config.maxConflictRetries else { throw Failure.tooManyConflicts }
                update { $0.phase = .pulling }
                try await pull()
                update { $0.phase = .pushing }
            }
            await refreshPending()
        }
    }

    private struct PlannedRecord {
        var key: String
        var payload: SyncPayload
        var plaintext: Data
        var hash: String
        var baseSeq: Int64?
        var sealed: Data
        /// Set when `sealed` is a pointer: the sealed record, wrapped as a blob, to upload before the push.
        var blob: (name: String, data: Data)?
    }

    private struct PlannedEntity {
        var entry: OutboxEntry
        var records: [PlannedRecord]
        var blobs: [BlobRef]
        var size: Int { records.reduce(0) { $0 + $1.sealed.count } }
        /// Bytes held in memory while planned: each record's plaintext, and its blob or inline sealed form.
        var plannedBytes: Int { records.reduce(0) { $0 + $1.plaintext.count + ($1.blob?.data.count ?? $1.sealed.count) } }
    }

    private static func thoughtKeys(_ entity: SyncEntity, _ keys: SyncKeys) -> [String] {
        guard entity.kind == .thought else { return [] }
        return [keys.recordKey(type: .thoughtContent, entityID: entity.id), keys.recordKey(type: .thoughtMeta, entityID: entity.id)]
    }

    private func pushBatch(_ entries: [OutboxEntry]) async throws -> BatchResult {
        let snapshots = try await local.snapshots(of: entries.map(\.entity))
        let keyed = snapshots.map { snapshot in
            snapshot.payloads.map { (payload: $0, key: keys.recordKey(type: $0.type, entityID: $0.entityID)) }
        }
        let allKeys = keyed.flatMap { $0.map(\.key) }
        var bases = try await state.records(forKeys: allKeys, includingContent: false)
        // Only a tag's push is decided by the synced content.
        let tagKeys = keyed.flatMap { $0.filter { if case .tag = $0.payload { true } else { false } }.map(\.key) }
        bases.merge(try await state.records(forKeys: tagKeys)) { _, withContent in withContent }
        let heldIDs = Set(try await state.held(entityIDs: entries.filter { $0.entity.kind == .thought }.map(\.entity.id)).map(\.entityID))
        let parkedKeys = try await state.parkedKeys(among: entries.flatMap { Self.thoughtKeys($0.entity, keys) } + keyed.flatMap { $0.map(\.key) })

        let gone = entries.indices.filter { entries[$0].entity.kind == .thought && !snapshots[$0].payloads.contains { $0.type == .thoughtContent && !$0.isDeletion } }
        try await state.forgetAttempts(entityIDs: gone.map { entries[$0].entity.id })

        var chunk: [PlannedEntity] = []
        var chunkRecords = 0
        var chunkBytes = 0
        var chunkPlanned = 0
        var finished: [OutboxEntry] = []
        var staleTags: [TagRecord] = []
        for (index, entry) in entries.enumerated() {
            let snapshot = snapshots[index]
            let entity = entry.entity
            // Never overwrite a server version this device hasn't applied: the local change stays queued.
            let thoughtKeys = Self.thoughtKeys(entity, keys)
            if (entity.kind == .thought && heldIDs.contains(entity.id))
                || (thoughtKeys + keyed[index].map(\.key)).contains(where: parkedKeys.contains) {
                waitingEntities.insert(entity)
                continue
            }
            var records: [PlannedRecord] = []
            var tooBig = false
            for (payload, key) in keyed[index] {
                let base = bases[key]
                if case .tag(let tag) = payload, let base, case .tag(let known)? = try? SyncPayload.decode(base.baseContent, supporting: config.payloadVersion),
                   RemoteMerge.tagWins(local: tag, remote: known) {
                    staleTags.append(known)
                    continue
                }
                if oversizedFingerprints[key] == payload.fingerprint {
                    tooBig = true
                    break
                }
                let plaintext = try payload.encoded()
                let hash = SyncPayload.hash(of: plaintext)
                if base?.baseHash == hash { continue }
                recordsSealed += 1
                var sealed = try SyncCrypto.seal(
                    plaintext, vaultID: vaultID, recordKey: key, payloadVersion: SyncPayload.currentVersion, keys: keys
                )
                guard sealed.count <= config.maxRecordBytes else {
                    oversizedFingerprints[key] = payload.fingerprint
                    tooBig = true
                    break
                }
                oversizedFingerprints[key] = nil
                var blob: (name: String, data: Data)?
                if sealed.count > config.maxInlinePayload {
                    // TODO(phase 2/3): the server should delete a pointer's blob once a newer version supersedes it.
                    let name = keys.recordBlobName(recordKey: key, hash: hash)
                    blob = (name, try SyncCrypto.sealBlob(sealed, vaultID: vaultID, name: name, keys: keys))
                    sealed = SyncCrypto.pointer(toBlob: name)
                }
                records.append(PlannedRecord(key: key, payload: payload, plaintext: plaintext, hash: hash, baseSeq: base?.seq, sealed: sealed, blob: blob))
            }
            if tooBig {
                oversizedEntities.insert(entity)
                continue
            }
            if records.isEmpty {
                finished.append(entry)
                continue
            }
            let wantsBlobs = records.contains { $0.payload.type == .thoughtContent && !$0.payload.isDeletion }
            let next = PlannedEntity(entry: entry, records: records, blobs: wantsBlobs ? snapshot.blobs : [])
            if !chunk.isEmpty, chunkRecords + next.records.count > config.maxRecordsPerPush || chunkBytes + next.size > config.maxBytesPerPush
                || chunkPlanned + next.plannedBytes > config.maxPlanBytes {
                if try await send(chunk) == .conflict { return .conflict }
                chunk = []
                chunkRecords = 0
                chunkBytes = 0
                chunkPlanned = 0
            }
            chunk.append(next)
            chunkRecords += next.records.count
            chunkBytes += next.size
            chunkPlanned += next.plannedBytes
            peakPlannedBytes = max(peakPlannedBytes, chunkPlanned)
        }
        if !staleTags.isEmpty {
            try checkActive()
            let outcome = await local.apply(RemoteBatch(tags: staleTags), now: clockNow())
            guard outcome.saved else { throw Failure.applyFailed }
        }
        if !finished.isEmpty { try checkActive(); try await state.markSynced([], dequeuing: finished) }

        if !chunk.isEmpty, try await send(chunk) == .conflict { return .conflict }
        return .done
    }

    private func send(_ planned: [PlannedEntity]) async throws -> BatchResult {
        guard let epoch = try await state.epoch() else { throw Failure.missingEpoch }
        do {
            return try await send(planned, epoch: epoch)
        } catch SyncTransportError.epochChanged(let server) {
            throw AttentionFailure(attention: .epochChanged(known: epoch, server: server))
        }
    }

    private func send(_ all: [PlannedEntity], epoch: Int64) async throws -> BatchResult {
        var planned = all
        if !transport.supportsBlobs {
            let needsBlobs = planned.filter { !$0.blobs.isEmpty || $0.records.contains { $0.blob != nil } }
            blobHeldEntities.formUnion(needsBlobs.map(\.entry.entity))
            planned.removeAll { entity in needsBlobs.contains { $0.entry.entity == entity.entry.entity } }
            guard !planned.isEmpty else { return .done }
        }
        let uploads = try await upload(Set(planned.flatMap(\.blobs)), epoch: epoch)
        let missing = uploads.missing
        var chunk = planned
        if !uploads.overQuota.isEmpty {
            let held = chunk.filter { !uploads.overQuota.isDisjoint(with: $0.blobs) }
            quotaHeldEntities.formUnion(held.map(\.entry.entity))
            chunk.removeAll { !uploads.overQuota.isDisjoint(with: $0.blobs) }
            guard !chunk.isEmpty else { return .done }
        }
        if !missing.isEmpty {
            // Only the thoughts whose attachments are gone wait. Dropping the reference would tell the server (and so the
            // other devices) that the attachment no longer exists, and they would delete a copy they still have.
            let held = chunk.filter { !missing.isDisjoint(with: $0.blobs) }
            missingAttachmentEntities.formUnion(held.map(\.entry.entity))
            chunk.removeAll { !missing.isDisjoint(with: $0.blobs) }
            guard !chunk.isEmpty else { return .done }
        }
        chunk = try await uploadRecordBlobs(of: chunk, epoch: epoch)
        guard !chunk.isEmpty else { return .done }
        try await state.noteAttempts(chunk.flatMap(\.records).filter { $0.baseSeq == nil && $0.payload.type == .thoughtContent && !$0.payload.isDeletion }
            .map { ($0.key, $0.payload.entityID, $0.hash, $0.plaintext) })
        let wire = chunk.flatMap(\.records).map {
            PushRecord(recordKey: $0.key, baseSeq: $0.baseSeq, payload: $0.sealed, deleted: $0.payload.isDeletion)
        }
        let result: PushResult
        do {
            var pushed = try await transport.push(wire, epoch: epoch)
            if case .blobsMissing = pushed {
                // A pointer's blob vanished after it was uploaded: upload again, and push once more.
                let reuploaded = try await uploadRecordBlobs(of: chunk, epoch: epoch)
                guard reuploaded.count == chunk.count else { return reuploaded.isEmpty ? .done : try await send(reuploaded, epoch: epoch) }
                pushed = try await transport.push(wire, epoch: epoch)
            }
            result = pushed
        } catch SyncTransportError.tooLarge {
            guard chunk.count > 1 else {
                oversizedEntities.insert(chunk[0].entry.entity)
                return .done
            }
            let middle = chunk.count / 2
            if try await send(Array(chunk[..<middle]), epoch: epoch) == .conflict { return .conflict }
            return try await send(Array(chunk[middle...]), epoch: epoch)
        }
        switch result {
        case .conflict:
            return .conflict
        case .blobsMissing(let names):
            throw Failure.blobsMissing(names)
        case .ok(let seqs, _):
            var synced: [SyncedRecord] = []
            for record in chunk.flatMap(\.records) {
                guard let seq = seqs[record.key] else { throw Failure.missingSeq(record.key) }
                synced.append(SyncedRecord(
                    recordKey: record.key, type: record.payload.type, entityID: record.payload.entityID, seq: seq,
                    fingerprint: record.payload.fingerprint, baseHash: record.hash, baseContent: record.plaintext
                ))
            }
            let deleted = chunk.filter { $0.records.contains { $0.payload.isDeletion } }.map { $0.entry.entity.id }
            try checkActive()
            try await state.markSynced(synced, dequeuing: chunk.map(\.entry))
            if !deleted.isEmpty { try await state.releaseHeld(entityIDs: deleted) }
            return .done
        }
    }

    /// Uploads the blobs behind the chunk's pointers. A thought whose blob would pass the vault's storage limit is held for
    /// the cycle (`Status.quotaExceededThoughts`) and left out of what is returned.
    private func uploadRecordBlobs(of chunk: [PlannedEntity], epoch: Int64) async throws -> [PlannedEntity] {
        var uploaded: [PlannedEntity] = []
        for entity in chunk {
            do {
                for blob in entity.records.compactMap(\.blob) {
                    try await transport.putBlob(name: blob.name, data: blob.data, epoch: epoch)
                }
                uploaded.append(entity)
            } catch SyncTransportError.quotaExceeded(let used, let limit) {
                quotaHeldEntities.insert(entity.entry.entity)
                lastQuota = BlobQuota(usedBytes: used, limitBytes: limit)
            }
        }
        return uploaded
    }

    /// Sends every blob through `putBlob`, which skips the ones the server already has and has the server re-upload the ones
    /// it is about to age out, so each push of a thought reads and seals its blobs again. Returns the blobs this device has
    /// no bytes for and the ones the server's storage limit refused.
    private func upload(_ refs: Set<BlobRef>, epoch: Int64) async throws -> (missing: Set<BlobRef>, overQuota: Set<BlobRef>) {
        guard !refs.isEmpty else { return ([], []) }
        let todo = refs.map { (name: keys.blobName(kind: $0.kind, id: $0.id), ref: $0) }.sorted { $0.name < $1.name }
        var missing = Set<BlobRef>()
        var overQuota = Set<BlobRef>()
        for start in stride(from: 0, to: todo.count, by: config.blobsPerRead) {
            let group = Array(todo[start..<min(start + config.blobsPerRead, todo.count)])
            let bytes = try await local.blobBytes(group.map(\.ref))
            for (name, ref) in group {
                guard let data = bytes[ref] else {
                    missing.insert(ref)
                    continue
                }
                let sealed = try SyncCrypto.sealBlob(data, vaultID: vaultID, name: name, keys: keys)
                do {
                    try await transport.putBlob(name: name, data: sealed, epoch: epoch)
                } catch SyncTransportError.quotaExceeded(let used, let limit) {
                    overQuota.insert(ref)
                    lastQuota = BlobQuota(usedBytes: used, limitBytes: limit)
                }
            }
        }
        return (missing, overQuota)
    }

    // MARK: Garbage collection

    /// After a cycle that went through, asks the server to delete the vault's blobs nothing uses any more, at most once every
    /// `SyncLimits.garbageCollectionInterval`. The server deletes whatever the live list leaves out, so it is only sent
    /// when this device has everything the vault has: nothing queued, held or parked, and nothing pulled since. Whatever the
    /// server answers, the attempt is noted and syncing goes on; the next clean cycle tries again.
    private func collectGarbageIfDue() async {
        guard !isShutDown, transport.supportsBlobs, status.attention == nil else { return }
        let now = clockNow()
        do {
            if quotaHeldEntities.isEmpty {
                quotaHitNoted = false
            } else if !quotaHitNoted {
                try await state.noteBlobQuotaHit(at: now)
                quotaHitNoted = true
            }
            guard try await state.garbageCollectionLog().isDue(at: now), let epoch = try await state.epoch() else { return }
            // Thoughts held only for the storage limit stay queued but don't block: the run is what frees the space.
            guard try await state.outboxCount() - quotaHeldEntities.count == 0, try await state.parkedCount() == 0,
                  try await state.heldCount() == 0 else { return }
            let cursor = try await state.cursor()
            let head = try await transport.head()
            guard head.epoch == epoch, head.headSeq == cursor else { return }
            guard let refs = try await local.allBlobRefs(limit: config.maxLiveListNames) else {
                Self.logger.error("Garbage collection skipped: more than \(self.config.maxLiveListNames) images and files")
                try await state.recordGarbageCollection(.tooManyBlobs, at: now)
                return
            }
            let list = Self.liveList(names: refs.map { keys.blobName(kind: $0.kind, id: $0.id) })
            switch try await transport.startGarbageCollection(liveList: list, epoch: epoch, asOfSeq: cursor) {
            case .started: try await state.recordGarbageCollection(.started, at: now)
            case .stale: try await state.recordGarbageCollection(.stale, at: now)
            case .liveListMissing: try await state.recordGarbageCollection(.liveListMissing, at: now)
            case .rateLimited(let seconds): try await state.recordGarbageCollection(.rateLimited, at: now, retryAfter: TimeInterval(seconds))
            }
        } catch is CancellationError {
            return
        } catch SyncTransportError.epochChanged(let server) {
            if let known = try? await state.epoch() { stop(.epochChanged(known: known, server: server)) }
        } catch {
            guard !isShutDown else { return }
            Self.logger.error("Garbage collection not started: \(error)")
            try? await state.recordGarbageCollection(.failed, at: now)
        }
    }

    /// One 43-character blob name per line, sorted and without repeats, every line ending in a newline.
    static func liveList(names: [String]) -> Data {
        Data(Set(names).sorted().map { $0 + "\n" }.joined().utf8)
    }
}
