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
/// - A 410 means the cursor is older than the server keeps: forget the progress, queue everything local
///   and pull everything; merging is by id and clock, so nothing is duplicated or lost.
/// - A changed epoch (the vault was erased elsewhere) stops syncing and shows up as `Status.attention`.
actor SyncEngine {
    struct Configuration: Sendable {
        var pullLimit = 200
        /// Outbox entities per push batch. A thought is two records, so 49 fit in the transport's 99.
        var pushEntities = 49
        var maxConflictRetries = 5
        var maxRecordsPerPush = SyncLimits.maxRecordsPerPush
        var maxBytesPerPush = SyncLimits.maxBytesPerPush
        var blobsPerRead = 8
        var maxApplyBytes = SyncLimits.maxApplyBytes
        /// The newest payload version this build reads; records past it are parked until the app is updated.
        var payloadVersion = SyncPayload.currentVersion
    }

    enum Phase: Sendable, Equatable {
        case idle, pulling, pushing, stopped
    }

    enum Attention: Sendable, Equatable {
        /// The vault was erased on another device (or replaced); this device must decide what to do. 1b only stops.
        case epochChanged(known: Int64, server: Int64)
    }

    struct Status: Sendable, Equatable {
        var phase: Phase = .idle
        /// Outbox entries left; during a first sync, how much is still to upload.
        var pending = 0
        var lastError: String?
        var attention: Attention?
        var cursor: Int64 = 0
        var headSeq: Int64?
        var cycles = 0
        /// Some records are from a newer version of the app and wait, still sealed, until it is updated. Syncing goes on.
        var updateRequired = false
        /// Thoughts held back because a blob is missing or their images belong to another thought; retried every cycle.
        var blockedThoughts = 0
        /// Queued local changes not pushed because the server's version of that thought is parked, blocked or held:
        /// they go out once it has been applied and merged.
        var waitingThoughts = 0
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case applyFailed
        case tooManyConflicts
        case goneAfterResync
        case invalidRecord(String)
        case missingSeq(String)
        case blobUnreadable(String)

        var description: String {
            switch self {
            case .applyFailed: "applying remote changes failed"
            case .tooManyConflicts: "too many conflicts"
            case .goneAfterResync: "the server answered 410 to a full resync"
            case .invalidRecord(let key): "record \(key) is not valid"
            case .missingSeq(let key): "no seq for \(key)"
            case .blobUnreadable(let name): "blob \(name) is not readable"
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
    private var cycleNumber = 0
    /// Queued thoughts left alone in this push because the server holds a version this device couldn't apply yet.
    private var waitingEntities: Set<SyncEntity> = []
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

    /// The periodic check: asks the server for its head and runs a cycle only if it moved (or there is
    /// something to push).
    @discardableResult
    func syncIfHeadMoved() async -> Bool {
        guard status.attention == nil else { return false }
        do {
            let head = try await transport.head()
            if let known = try await state.epoch(), known != head.epoch {
                stop(.epochChanged(known: known, server: head.epoch))
                return false
            }
            guard head.headSeq != status.headSeq else {
                if try await state.outboxCount() > 0 {
                    await syncNow()
                    return true
                }
                return false
            }
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
                try await retryBlocked()
                _ = try await pull()
                try await resolveResync()
                update { $0.phase = .pushing }
                try await push()
                update {
                    $0.phase = .idle
                    $0.lastError = nil
                    $0.cycles += 1
                }
            } catch let failure as AttentionFailure {
                stop(failure.attention)
            } catch {
                record(error)
            }
            await refreshPending()
        } while rerun && status.lastError == nil && status.attention == nil
        running = nil
    }

    private struct AttentionFailure: Error {
        var attention: Attention
    }

    private func stop(_ attention: Attention) {
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
        let parked = (try? await state.parkedCount()) ?? 0
        let blocked = (try? await state.blockedEntityIDs().count) ?? status.blockedThoughts
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

    /// A record this version can't interpret (a newer payload version, an unknown type) is parked, not an error. One that
    /// fails to decrypt is: it was damaged or tampered with, and the cycle stops.
    private func read(_ record: PulledRecord) throws -> Reading {
        let opened = try SyncCrypto.open(record.payload, vaultID: vaultID, recordKey: record.recordKey, keys: keys)
        let parked = Reading.parked(ParkedRecord(recordKey: record.recordKey, seq: record.seq, payload: record.payload, deleted: record.deleted))
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

    /// Pulls until caught up. True if a 410 made it start over.
    private func pull() async throws -> Bool {
        var startedOver = false
        var fromScratch = try await state.cursor() == 0
        while true {
            let cursor = try await state.cursor()
            switch try await transport.pull(after: cursor, limit: config.pullLimit, fullResync: fromScratch) {
            case .gone:
                guard !startedOver else { throw Failure.goneAfterResync }
                startedOver = true
                fromScratch = true
                try await state.resetSyncProgress(keepingBlobs: true, keepingEpoch: true, snapshotting: true)
                await local.reconcile()
            case .page(let page):
                try await apply(page, after: cursor)
                update { $0.headSeq = page.headSeq }
                if !page.hasMore { return startedOver }
            }
        }
    }

    private func apply(_ page: PullPage, after cursor: Int64) async throws {
        if let known = try await state.epoch(), known != page.epoch {
            throw AttentionFailure(attention: .epochChanged(known: known, server: page.epoch))
        }
        var decoded: [Decoded] = []
        var commit = PageCommit(
            cursor: page.hasMore ? (page.records.last?.seq ?? cursor) : max(page.records.last?.seq ?? cursor, page.headSeq), epoch: page.epoch
        )
        for record in page.records {
            switch try read(record) {
            case .readable(let item): decoded.append(item)
            case .parked(let parked): commit.park.append(parked)
            }
        }
        commit.unpark = decoded.map(\.record.recordKey)
        try await process(decoded, retrying: [], commit: &commit)
    }

    /// Parked records this version can read now (it was updated) are applied before anything new.
    private func reapplyParked() async throws {
        let parked = try await state.parked()
        guard !parked.isEmpty, let epoch = try await state.epoch() else { return }
        let bases = try await state.records(forKeys: parked.map(\.recordKey))
        for record in parked {
            // One record that won't apply is logged and stays parked; it must not stop the rest of the cycle.
            do {
                guard case .readable(let item) = try read(PulledRecord(recordKey: record.recordKey, seq: record.seq, payload: record.payload, deleted: record.deleted))
                else { continue }
                var commit = PageCommit(cursor: try await state.cursor(), epoch: epoch)
                commit.unpark = [record.recordKey]
                let superseded = bases[record.recordKey].map { $0.seq >= record.seq } ?? false
                try await process(superseded ? [] : [item], retrying: [], commit: &commit)
            } catch {
                Self.logger.error("Parked record \(record.recordKey) not applied this cycle: \(error)")
            }
        }
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

    /// After a full resync: a thought this device had synced that the server no longer has was deleted elsewhere and its
    /// tombstone pruned. Unless it was edited here since, it goes; one never synced is simply uploaded.
    private func resolveResync() async throws {
        guard try await state.hasResyncSnapshot() else { return }
        let parked = try await state.parkedKeys()
        var unresolved: [(id: String, fingerprint: String)] = []
        var after: String?
        while true {
            let page = try await state.missingFromServer(after: after, limit: 200)
            guard let last = page.last else { break }
            after = last.id
            // The server has these, but this version couldn't take them in yet (parked, blocked or held), so they have
            // no record here. They stay in the snapshot until they apply.
            let held = Set(try await state.held(entityIDs: page.map(\.id)).map(\.entityID))
            var deletable: [String: String] = [:]
            for candidate in page {
                let isWaiting = held.contains(candidate.id)
                    || parked.contains(keys.recordKey(type: .thoughtContent, entityID: candidate.id))
                    || parked.contains(keys.recordKey(type: .thoughtMeta, entityID: candidate.id))
                if isWaiting {
                    unresolved.append(candidate)
                } else {
                    deletable[candidate.id] = candidate.fingerprint
                }
            }
            guard await local.discardUnchanged(deletable, now: clockNow()) else { throw Failure.applyFailed }
        }
        try await state.replaceResyncSnapshot(unresolved)
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
            if let base = lastSynced[keys.recordKey(type: .thoughtContent, entityID: idString)] {
                remote.contentBaseHash = base.baseHash
                if case .thoughtContent(let content)? = try? SyncPayload.decode(base.baseContent, supporting: config.payloadVersion) { remote.contentBase = content }
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
        for var thought in thoughts {
            let size: Int
            do {
                size = try await download(into: &thought, missing: missing)
            } catch let failure as BlobFailure {
                blocked.insert(thought.id)
                let key = thought.id.uuidString
                if failure.unreadable {
                    let attempts = (unreadableBackoff[key]?.attempts ?? 0) + 1
                    unreadableBackoff[key] = (attempts, cycleNumber + min(1 << attempts, 32))
                } else {
                    unreadableBackoff[key] = nil
                }
                continue
            }
            unreadableBackoff[thought.id.uuidString] = nil
            if !work.pending.isEmpty, work.bytes + size > config.maxApplyBytes { try await flush(&work) }
            work.pending.append(thought)
            work.bytes += size
            // Only the tags are kept past the sub-batch, so its downloaded blobs can be released.
            appliedTags[thought.id] = Self.tagEntities(in: thought.content.map { [$0] } ?? [])
        }
        try await flush(&work, tags: batch.tags, settings: batch.settings)
        let outcome = work.outcome

        let unsettled = blocked.union(outcome.rejected)
        var freshKeys = Set<String>()
        for item in fresh {
            freshKeys.insert(item.record.recordKey)
            let entityID = item.payload.entityID
            let id = freshByThought[entityID] != nil ? UUID(uuidString: entityID) : nil
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
            guard let id = UUID(uuidString: entityID), !unsettled.contains(id), !outcome.held.contains(id) else { continue }
            for row in rows where !freshKeys.contains(row.recordKey) {
                guard let payload = try? SyncPayload.decode(row.payload, supporting: config.payloadVersion) else { continue }
                commit.records.append(SyncedRecord(
                    recordKey: row.recordKey, type: row.type, entityID: entityID, seq: row.seq,
                    fingerprint: payload.fingerprint, baseHash: SyncPayload.hash(of: row.payload), baseContent: row.payload
                ))
            }
        }
        commit.release = thoughtIDs.filter {
            let id = UUID(uuidString: $0) ?? UUID()
            return !outcome.held.contains(id) && !unsettled.contains(id)
        }
        commit.requeue = Array(outcome.requeue) + appliedTags.filter { !unsettled.contains($0.key) }.flatMap(\.value)
        try await state.commit(commit)
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
    private func download(into thought: inout RemoteThought, missing: Set<BlobRef>) async throws -> Int {
        guard let content = thought.content, !missing.isEmpty else { return 0 }
        let imageIDs = Set((content.images + content.blocks.flatMap(\.images)).map(\.id))
        let fileRecords = Dictionary(content.blocks.compactMap(\.file).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var size = 0
        for ref in missing {
            let name = keys.blobName(kind: ref.kind, id: ref.id)
            switch ref.kind {
            case .image where imageIDs.contains(ref.id), .file where fileRecords[ref.id] != nil:
                do {
                    let sealed = try await transport.getBlob(name: name)
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
                } catch SyncTransportError.blobMissing(_) {
                    throw BlobFailure(unreadable: false)
                } catch is SyncCrypto.Failure, is ImageProcessingError, is FileProcessingError {
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
        defer { let waiting = waitingEntities.count; update { $0.waitingThoughts = waiting } }
        while true {
            let entries = try await state.outbox(limit: config.pushEntities, after: after)
            guard let last = entries.last else { break }
            switch try await pushBatch(entries) {
            case .done:
                after = last.entity
            case .conflict:
                conflicts += 1
                guard conflicts <= config.maxConflictRetries else { throw Failure.tooManyConflicts }
                update { $0.phase = .pulling }
                if try await pull() { after = nil }
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
    }

    private struct PlannedEntity {
        var entry: OutboxEntry
        var records: [PlannedRecord]
        var blobs: [BlobRef]
        var size: Int { records.reduce(0) { $0 + $1.sealed.count } }
    }

    private func pushBatch(_ entries: [OutboxEntry]) async throws -> BatchResult {
        let snapshots = try await local.snapshots(of: entries.map(\.entity))
        let keyed = snapshots.map { snapshot in
            snapshot.payloads.map { (payload: $0, key: keys.recordKey(type: $0.type, entityID: $0.entityID)) }
        }
        let bases = try await state.records(forKeys: keyed.flatMap { $0.map(\.key) })
        let heldIDs = Set(try await state.held(entityIDs: entries.filter { $0.entity.kind == .thought }.map(\.entity.id)).map(\.entityID))
        let parkedKeys = try await state.parkedKeys()

        var planned: [PlannedEntity] = []
        var finished: [OutboxEntry] = []
        var staleTags: [TagRecord] = []
        for (index, entry) in entries.enumerated() {
            let snapshot = snapshots[index]
            let entity = entry.entity
            // Never overwrite a server version this device hasn't applied: the local change stays queued.
            if entity.kind == .thought, heldIDs.contains(entity.id)
                || parkedKeys.contains(keys.recordKey(type: .thoughtContent, entityID: entity.id))
                || parkedKeys.contains(keys.recordKey(type: .thoughtMeta, entityID: entity.id)) {
                waitingEntities.insert(entity)
                continue
            }
            var records: [PlannedRecord] = []
            for (payload, key) in keyed[index] {
                let base = bases[key]
                if case .tag(let tag) = payload, let base, case .tag(let known)? = try? SyncPayload.decode(base.baseContent, supporting: config.payloadVersion),
                   RemoteMerge.tagWins(local: tag, remote: known) {
                    staleTags.append(known)
                    continue
                }
                let plaintext = try payload.encoded()
                let hash = SyncPayload.hash(of: plaintext)
                if base?.baseHash == hash { continue }
                let sealed = try SyncCrypto.seal(
                    plaintext, vaultID: vaultID, recordKey: key, payloadVersion: SyncPayload.currentVersion, keys: keys
                )
                records.append(PlannedRecord(key: key, payload: payload, plaintext: plaintext, hash: hash, baseSeq: base?.seq, sealed: sealed))
            }
            if records.isEmpty {
                finished.append(entry)
            } else {
                let wantsBlobs = records.contains { $0.payload.type == .thoughtContent && !$0.payload.isDeletion }
                planned.append(PlannedEntity(entry: entry, records: records, blobs: wantsBlobs ? snapshot.blobs : []))
            }
        }
        if !staleTags.isEmpty {
            let outcome = await local.apply(RemoteBatch(tags: staleTags), now: clockNow())
            guard outcome.saved else { throw Failure.applyFailed }
        }
        if !finished.isEmpty { try await state.markSynced([], dequeuing: finished) }

        var chunk: [PlannedEntity] = []
        var chunkRecords = 0
        var chunkBytes = 0
        for entity in planned {
            if !chunk.isEmpty, chunkRecords + entity.records.count > config.maxRecordsPerPush || chunkBytes + entity.size > config.maxBytesPerPush {
                if try await send(chunk) == .conflict { return .conflict }
                chunk = []
                chunkRecords = 0
                chunkBytes = 0
            }
            chunk.append(entity)
            chunkRecords += entity.records.count
            chunkBytes += entity.size
        }
        if !chunk.isEmpty, try await send(chunk) == .conflict { return .conflict }
        return .done
    }

    private func send(_ chunk: [PlannedEntity]) async throws -> BatchResult {
        try await upload(Set(chunk.flatMap(\.blobs)))
        let result = try await transport.push(chunk.flatMap(\.records).map {
            PushRecord(recordKey: $0.key, baseSeq: $0.baseSeq, payload: $0.sealed, deleted: $0.payload.isDeletion)
        })
        switch result {
        case .conflict:
            return .conflict
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
            try await state.markSynced(synced, dequeuing: chunk.map(\.entry))
            if !deleted.isEmpty { try await state.releaseHeld(entityIDs: deleted) }
            return .done
        }
    }

    /// Uploads the blobs the server doesn't have, each once: the ones `sync.sqlite` shows as uploaded are skipped,
    /// and the server is asked about the rest before sending bytes.
    private func upload(_ refs: Set<BlobRef>) async throws {
        guard !refs.isEmpty else { return }
        let named = Dictionary(refs.map { (keys.blobName(kind: $0.kind, id: $0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let done = try await state.uploadedBlobs(among: Array(named.keys))
        let todo = named.filter { !done.contains($0.key) }.sorted { $0.key < $1.key }
        var uploaded: [String] = []
        for group in stride(from: 0, to: todo.count, by: config.blobsPerRead).map({ Array(todo[$0..<min($0 + config.blobsPerRead, todo.count)]) }) {
            var bytes: [BlobRef: Data] = [:]
            var needed: [(name: String, ref: BlobRef)] = []
            for (name, ref) in group {
                if try await transport.hasBlob(name: name) {
                    uploaded.append(name)
                } else {
                    needed.append((name, ref))
                }
            }
            if !needed.isEmpty { bytes = try await local.blobBytes(needed.map(\.ref)) }
            for (name, ref) in needed {
                guard let data = bytes[ref] else { throw SyncTransportError.blobMissing(name) }
                let sealed = try SyncCrypto.sealBlob(data, vaultID: vaultID, name: name, keys: keys)
                try await transport.putBlob(name: name, data: sealed)
                uploaded.append(name)
            }
            try await state.markBlobsUploaded(uploaded)
            uploaded = []
        }
    }
}
