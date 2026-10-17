import Foundation
import SQLite3
import os

/// A record as last synced with the server.
struct SyncedRecord: Sendable, Equatable {
    var recordKey: String
    var type: SyncRecordType
    var entityID: String
    /// The server's seq for the version synced.
    var seq: Int64
    /// `SyncFingerprint` of the local state that produced (or was produced by) this version.
    var fingerprint: String
    var baseHash: String
    /// The plaintext payload of the synced version: the base of a later 3-way merge.
    var baseContent: Data
}

/// A pulled record not applied yet because the thought's other record hasn't arrived (see `RemoteOutcome.held`).
/// The payload is the plaintext, like `SyncedRecord.baseContent`.
struct HeldRecord: Sendable, Equatable {
    var recordKey: String
    var type: SyncRecordType
    var entityID: String
    var seq: Int64
    var payload: Data
    /// Held because applying it failed for a reason that can clear up (a blob not on the server yet, an image
    /// that belongs to another thought), not because the thought's other record is still to come. Retried every cycle.
    var blocked = false
}

/// A pulled record this version can't read (a newer payload version, an unknown type or frame), kept still sealed.
struct ParkedRecord: Sendable, Equatable {
    var recordKey: String
    var seq: Int64
    var payload: Data
    var deleted: Bool
    /// A pointer parked because its blob is in a frame from a newer app. Unlike other pointers, which are retried every
    /// cycle for a blob that isn't there or readable yet, it waits for an update.
    var needsUpdate = false
}

/// Everything a pulled page changes in `sync.sqlite`, committed together: if applying the page failed, none of it is.
struct PageCommit: Sendable {
    var records: [SyncedRecord] = []
    var hold: [HeldRecord] = []
    /// Entity ids whose held records are done with (applied, deleted or superseded).
    var release: [String] = []
    var park: [ParkedRecord] = []
    /// Record keys that were read this time, so any parked copy is dropped.
    var unpark: [String] = []
    /// Entities to push after this page; queued in the same transaction, so a crash can't lose them.
    var requeue: [SyncEntity] = []
    /// Entities deleted remotely: the base noted for a merge is of no use any more.
    var forgetAttempts: [String] = []
    var cursor: Int64
    var epoch: Int64
}

enum GarbageCollectionOutcome: String, Sendable, Equatable {
    case started
    case stale
    case liveListMissing
    case rateLimited
    /// The call failed or the server refused it. Never stops syncing.
    case failed
    /// More blobs than a live list may name (`SyncLimits.maxLiveListNames`); nothing was sent.
    case tooManyBlobs
}

/// When garbage collection last ran or was tried on this device, for spacing the runs and for the Sync lab.
struct GarbageCollectionLog: Sendable, Equatable {
    /// When the server last accepted a run; the next one waits `SyncLimits.garbageCollectionInterval` from here.
    var lastStartedAt: Date?
    /// The server's rate limit: no attempt before this.
    var retryNotBefore: Date?
    var lastAttemptAt: Date?
    var lastOutcome: GarbageCollectionOutcome?
    /// When the server first refused an upload for the storage limit since the last accepted run: a run is wanted at once,
    /// to free space, instead of after the week.
    var quotaHitAt: Date?
}

extension GarbageCollectionLog {
    /// Whether a run may be asked for at `now`. Never before the server's rate limit has passed, nor within
    /// `SyncLimits.garbageCollectionRetryGap` of an attempt the server didn't accept (each attempt uploads the whole list).
    /// Then due at once after a storage limit refusal, else a week after the last accepted run. A clock set back behind the
    /// last attempt or run counts as past it, so a wrong date can't block a run for good.
    func isDue(at now: Date) -> Bool {
        if let retryNotBefore, now < retryNotBefore { return false }
        if let lastAttemptAt, lastOutcome != .started, now >= lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) < SyncLimits.garbageCollectionRetryGap { return false }
        if quotaHitAt != nil { return true }
        guard let lastStartedAt else { return true }
        return now < lastStartedAt || now.timeIntervalSince(lastStartedAt) >= SyncLimits.garbageCollectionInterval
    }
}

struct OutboxEntry: Sendable, Equatable {
    var entity: SyncEntity
    /// Bumped by every enqueue of the same entity; `markSynced` dequeues only the generation it pushed.
    var generation: Int64
    var enqueuedAt: Date
}

/// What sync knows about this device's copy of the library, in a SQLite file of its own beside the
/// SwiftData store: the pull cursor, the outbox of entities to push, and what was last synced for each
/// record. Derived data, never the source of truth: if the file is lost, `SyncReconciler` queues
/// everything again and the engine pulls everything.
///
/// Sync is on only once a vault is configured. While it is off the file doesn't exist and `enqueue`
/// returns at once. Like `SearchIndex`, writes arrive through a fire-and-forget `enqueue` that the actor
/// applies in order, and every other method applies the ones still queued first.
///
/// A file that is damaged or from another schema version is deleted and recreated empty. The vault
/// survives that only if it was configured or read in this process; a file damaged at a fresh launch
/// has lost it, and sync turns off. So a later phase must call `configure(vaultID:)` from its durable
/// source (the Keychain) on every launch. Any other open error is logged and leaves sync off for this
/// launch, with the file untouched.
///
/// The outbox says "this entity may have changed", not what changed. Some content changes don't move
/// a clock, so the engine must push every entry and use the base hash of the sealed payload to skip a
/// no-op; a fingerprint match only means the clocks agree.
actor SyncState {
    enum Location: Sendable {
        case file(URL)
        case inMemory
    }

    enum Failure: Error, Equatable {
        case notConfigured
    }

    /// The app's state, in Application Support. Under tests, previews and screenshot mode it is in memory.
    static let shared = SyncState(location: SearchIndex.isRunningTestsOrPreviews ? .inMemory : .file(defaultFileURL))

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Sync", directoryHint: .isDirectory).appending(path: "sync.sqlite")
    }

    private static let schemaVersion: Int32 = 2
    private static let logger = Logger(subsystem: "com.thoughtreps", category: "sync")

    private struct Queued: Sendable {
        var entities: [SyncEntity]
        var at: Date
    }

    private struct Gate {
        var isEnabled: Bool
        var pending: [Queued] = []
        var wipeNeeded = false
        var observer: (@Sendable () -> Void)?
    }

    nonisolated let location: Location
    private nonisolated let gate: OSAllocatedUnfairLock<Gate>
    private var database: SQLiteDatabase?
    private var vaultID: String?

    /// A file location starts enabled if the file exists; the vault is read from it on first use.
    init(location: Location) {
        self.location = location
        var exists = false
        if case .file(let url) = location { exists = FileManager.default.fileExists(atPath: url.path) }
        gate = OSAllocatedUnfairLock(initialState: Gate(isEnabled: exists))
    }

    /// Whether sync is on. Cheap and safe from any thread.
    nonisolated var isEnabled: Bool {
        gate.withLock { $0.isEnabled }
    }

    // MARK: Turning on and off

    /// Turns sync on for `vaultID`, creating the file. A file left by another vault is cleared first.
    func configure(vaultID: String) throws {
        applyPending()
        if let current = self.vaultID, current != vaultID { wipe() }
        self.vaultID = vaultID
        do {
            _ = try open()
        } catch {
            self.vaultID = nil
            throw error
        }
        gate.withLock { $0.isEnabled = true }
    }

    /// Turns sync off and deletes the file: "erase this device and leave sync". Takes effect for
    /// `enqueue` at once; the file goes shortly after.
    nonisolated func disable() {
        gate.withLock {
            $0.isEnabled = false
            $0.pending = []
            $0.wipeNeeded = true
        }
        Task { await self.flush() }
    }

    func configuredVaultID() throws -> String? {
        applyPending()
        if vaultID == nil { _ = try? open() }
        return vaultID
    }

    // MARK: Outbox

    /// Queues entities for pushing and returns at once; the actor applies it shortly after. Idempotent:
    /// an entity is queued once, and queueing it again only bumps its generation.
    nonisolated func enqueue(_ entities: [SyncEntity]) {
        guard !entities.isEmpty else { return }
        let accepted = gate.withLock { gate in
            guard gate.isEnabled else { return false }
            gate.pending.append(Queued(entities: entities, at: .now))
            return true
        }
        if accepted {
            Task { await self.flush() }
            gate.withLock { $0.observer }?()
        }
    }

    /// Called after every accepted `enqueue`, from any thread; the sync triggers use it to debounce a push.
    nonisolated func setEnqueueObserver(_ observer: (@Sendable () -> Void)?) {
        gate.withLock { $0.observer = observer }
    }

    /// Returns once everything enqueued so far is applied.
    func flush() {
        applyPending()
    }

    /// Up to `limit` entries ordered by entity, starting after `after`.
    func outbox(limit: Int, after: SyncEntity? = nil) throws -> [OutboxEntry] {
        try perform { database in
            var entries: [OutboxEntry] = []
            let sql = "SELECT kind, id, generation, enqueued_at FROM outbox "
                + (after == nil ? "" : "WHERE (kind, id) > (?, ?) ")
                + "ORDER BY kind, id LIMIT ?"
            var binds: [SQLiteValue] = []
            if let after { binds += [.text(after.kind.rawValue), .text(after.id)] }
            binds.append(.int(Int64(limit)))
            try database.query(sql, binds) { row in
                guard let kind = SyncEntityKind(rawValue: row.text(0)) else { return }
                entries.append(OutboxEntry(
                    entity: SyncEntity(kind: kind, id: row.text(1)), generation: row.int(2),
                    enqueuedAt: Date(timeIntervalSinceReferenceDate: row.double(3))
                ))
            }
            return entries
        }
    }

    func outboxCount() throws -> Int {
        try perform { database in
            var total = 0
            try database.query("SELECT count(*) FROM outbox") { total = Int($0.int(0)) }
            return total
        }
    }

    // MARK: Synced records

    /// Records the confirmed versions and, in the same transaction, dequeues each entry whose
    /// generation is still the one pushed. An entity written again during the push stays queued.
    /// Returns how many entries were dequeued.
    @discardableResult
    func markSynced(_ records: [SyncedRecord], dequeuing entries: [OutboxEntry] = []) throws -> Int {
        try perform { database in
            var dequeued = 0
            try database.transaction {
                for record in records {
                    try Self.write(record, in: database)
                }
                for entry in entries {
                    try database.execute(
                        "DELETE FROM outbox WHERE kind = ? AND id = ? AND generation = ?",
                        [.text(entry.entity.kind.rawValue), .text(entry.entity.id), .int(entry.generation)]
                    )
                    dequeued += database.changes
                }
            }
            return dequeued
        }
    }

    /// The synced records for a set of keys, in one query per few hundred. Without `includingContent` the
    /// `baseContent` is left empty, for callers that need only the seq and hash.
    func records(forKeys keys: [String], includingContent: Bool = true) throws -> [String: SyncedRecord] {
        try perform { database in
            var found: [String: SyncedRecord] = [:]
            for start in stride(from: 0, to: keys.count, by: 500) {
                let chunk = Array(keys[start..<min(start + 500, keys.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                try database.query(
                    "SELECT record_key, type, entity_id, seq, fingerprint, base_hash, \(includingContent ? "base_content" : "NULL") FROM records WHERE record_key IN (\(marks))",
                    chunk.map(SQLiteValue.text)
                ) { row in
                    guard let type = SyncRecordType(rawValue: row.text(1)) else { return }
                    found[row.text(0)] = SyncedRecord(
                        recordKey: row.text(0), type: type, entityID: row.text(2), seq: row.int(3),
                        fingerprint: row.text(4), baseHash: row.text(5), baseContent: row.data(6) ?? Data()
                    )
                }
            }
            return found
        }
    }

    /// Notes the plaintext of a record about to be pushed for the first time. If the response is lost, it is the only
    /// trace of the version the server may now hold, and so the base for a merge when another device edits it first.
    func noteAttempts(_ attempts: [(recordKey: String, entityID: String, hash: String, plaintext: Data)]) throws {
        guard !attempts.isEmpty else { return }
        try perform { database in
            try database.transaction {
                for attempt in attempts {
                    try database.execute(
                        "INSERT OR IGNORE INTO attempts(record_key, entity_id, base_hash, content) VALUES(?, ?, ?, ?)",
                        [.text(attempt.recordKey), .text(attempt.entityID), .text(attempt.hash), .blob(attempt.plaintext)]
                    )
                }
            }
        }
    }

    /// Drops the noted attempts of entities that have nothing left to push (deleted before the first push was acknowledged).
    func forgetAttempts(entityIDs: [String]) throws {
        guard !entityIDs.isEmpty else { return }
        try perform { database in
            try database.transaction {
                for id in entityIDs { try database.execute("DELETE FROM attempts WHERE entity_id = ?", [.text(id)]) }
            }
        }
    }

    func attemptCount() throws -> Int {
        try perform { database in
            var total = 0
            try database.query("SELECT count(*) FROM attempts") { total = Int($0.int(0)) }
            return total
        }
    }

    /// The noted attempts for records that have no synced base yet.
    func attempts(forKeys keys: [String]) throws -> [String: (hash: String, plaintext: Data)] {
        try perform { database in
            var found: [String: (hash: String, plaintext: Data)] = [:]
            for start in stride(from: 0, to: keys.count, by: 500) {
                let chunk = Array(keys[start..<min(start + 500, keys.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                try database.query(
                    "SELECT record_key, base_hash, content FROM attempts WHERE record_key IN (\(marks))", chunk.map(SQLiteValue.text)
                ) { row in
                    found[row.text(0)] = (row.text(1), row.data(2) ?? Data())
                }
            }
            return found
        }
    }

    func record(forKey recordKey: String) throws -> SyncedRecord? {
        try perform { database in
            var found: SyncedRecord?
            try database.query(
                "SELECT record_key, type, entity_id, seq, fingerprint, base_hash, base_content FROM records WHERE record_key = ?",
                [.text(recordKey)]
            ) { row in
                guard let type = SyncRecordType(rawValue: row.text(1)) else { return }
                found = SyncedRecord(
                    recordKey: row.text(0), type: type, entityID: row.text(2), seq: row.int(3),
                    fingerprint: row.text(4), baseHash: row.text(5), baseContent: row.data(6) ?? Data()
                )
            }
            return found
        }
    }

    /// The synced fingerprint of each entity of `type` that has a record.
    func fingerprints(type: SyncRecordType, entityIDs: [String]) throws -> [String: String] {
        try perform { database in
            var result: [String: String] = [:]
            for start in stride(from: 0, to: entityIDs.count, by: 500) {
                let chunk = Array(entityIDs[start..<min(start + 500, entityIDs.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                try database.query(
                    "SELECT entity_id, fingerprint FROM records WHERE type = ? AND entity_id IN (\(marks))",
                    [.text(type.rawValue)] + chunk.map(SQLiteValue.text)
                ) { result[$0.text(0)] = $0.text(1) }
            }
            return result
        }
    }

    func recordCount() throws -> Int {
        try perform { database in
            var total = 0
            try database.query("SELECT count(*) FROM records") { total = Int($0.int(0)) }
            return total
        }
    }

    // MARK: Pulled pages and held records

    /// Commits a pulled page: its record bases, the records held back, the cursor and the epoch, in one transaction.
    func commit(_ page: PageCommit) throws {
        try perform { database in
            try database.transaction {
                for record in page.records {
                    try Self.write(record, in: database)
                }
                for entityID in page.forgetAttempts {
                    try database.execute("DELETE FROM attempts WHERE entity_id = ?", [.text(entityID)])
                }
                for entityID in page.release {
                    try database.execute("DELETE FROM held WHERE entity_id = ?", [.text(entityID)])
                }
                for held in page.hold {
                    try database.execute(
                        "INSERT OR REPLACE INTO held(record_key, type, entity_id, seq, payload, blocked) VALUES(?, ?, ?, ?, ?, ?)",
                        [
                            .text(held.recordKey), .text(held.type.rawValue), .text(held.entityID), .int(held.seq), .blob(held.payload),
                            .int(held.blocked ? 1 : 0),
                        ]
                    )
                }
                for key in page.unpark {
                    try database.execute("DELETE FROM parked WHERE record_key = ?", [.text(key)])
                }
                for parked in page.park {
                    try database.execute(
                        "INSERT OR REPLACE INTO parked(record_key, seq, payload, deleted, needs_update) VALUES(?, ?, ?, ?, ?)",
                        [
                            .text(parked.recordKey), .int(parked.seq), .blob(parked.payload), .int(parked.deleted ? 1 : 0),
                            .int(parked.needsUpdate ? 1 : 0),
                        ]
                    )
                }
                for entity in page.requeue {
                    try database.execute(
                        """
                        INSERT INTO outbox(kind, id, generation, enqueued_at) VALUES(?, ?, 1, ?)
                        ON CONFLICT(kind, id) DO UPDATE SET generation = generation + 1
                        """,
                        [.text(entity.kind.rawValue), .text(entity.id), .double(Date.now.timeIntervalSinceReferenceDate)]
                    )
                }
                try Self.setMeta("cursor", String(page.cursor), in: database)
                try Self.setMeta("epoch", String(page.epoch), in: database)
            }
        }
        if !page.requeue.isEmpty { gate.withLock { $0.observer }?() }
    }

    func held(entityIDs: [String]) throws -> [HeldRecord] {
        try perform { database in
            var found: [HeldRecord] = []
            for start in stride(from: 0, to: entityIDs.count, by: 500) {
                let chunk = Array(entityIDs[start..<min(start + 500, entityIDs.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                try database.query(
                    "SELECT record_key, type, entity_id, seq, payload, blocked FROM held WHERE entity_id IN (\(marks))",
                    chunk.map(SQLiteValue.text)
                ) { row in
                    guard let type = SyncRecordType(rawValue: row.text(1)) else { return }
                    found.append(HeldRecord(
                        recordKey: row.text(0), type: type, entityID: row.text(2), seq: row.int(3), payload: row.data(4) ?? Data(),
                        blocked: row.int(5) != 0
                    ))
                }
            }
            return found
        }
    }

    /// The thoughts with a record held back for a reason that can clear up.
    func blockedEntityIDs() throws -> [String] {
        try perform { database in
            var ids: [String] = []
            try database.query("SELECT DISTINCT entity_id FROM held WHERE blocked = 1 ORDER BY entity_id") { ids.append($0.text(0)) }
            return ids
        }
    }

    /// Up to `limit` parked records ordered by seq and key, starting after `after`, so a long list is never held whole.
    /// Pointers waiting for a blob (`needsUpdate` false) are left out: `parkedPointers` has those.
    func parked(after: (seq: Int64, key: String)? = nil, limit: Int) throws -> [ParkedRecord] {
        try perform { database in
            var found: [ParkedRecord] = []
            let sql = """
                SELECT record_key, seq, payload, deleted, needs_update FROM parked
                WHERE (substr(payload, 1, 4) != ? OR needs_update = 1)\(after == nil ? "" : " AND (seq, record_key) > (?, ?)")
                ORDER BY seq, record_key LIMIT ?
                """
            var binds: [SQLiteValue] = [.blob(SyncCrypto.pointerMagic)]
            if let after { binds += [.int(after.seq), .text(after.key)] }
            binds.append(.int(Int64(limit)))
            try database.query(sql, binds) { found.append(Self.parkedRecord($0)) }
            return found
        }
    }

    private static func parkedRecord(_ row: SQLiteRow) -> ParkedRecord {
        ParkedRecord(
            recordKey: row.text(0), seq: row.int(1), payload: row.data(2) ?? Data(), deleted: row.int(3) != 0, needsUpdate: row.int(4) != 0
        )
    }

    /// Which of `keys` are parked.
    func parkedKeys(among keys: [String]) throws -> Set<String> {
        try perform { database in
            var found = Set<String>()
            for start in stride(from: 0, to: keys.count, by: 500) {
                let chunk = Array(keys[start..<min(start + 500, keys.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                try database.query("SELECT record_key FROM parked WHERE record_key IN (\(marks))", chunk.map(SQLiteValue.text)) { found.insert($0.text(0)) }
            }
            return found
        }
    }

    /// The reader version (`SyncCrypto.readerVersion`) the parked records were last tried with; they are tried again only when it changes.
    func parkedVersionTried() throws -> Int? {
        try perform { try Self.meta("parked_version", in: $0).flatMap { Int($0) } }
    }

    func setParkedVersionTried(_ version: Int) throws {
        try perform { try Self.setMeta("parked_version", String(version), in: $0) }
    }

    /// Parked records that are pointers to a blob that couldn't be fetched or read yet (retried every cycle, unlike
    /// the ones parked for their version).
    func parkedPointers() throws -> [ParkedRecord] {
        try perform { database in
            var found: [ParkedRecord] = []
            try database.query(
                "SELECT record_key, seq, payload, deleted, needs_update FROM parked WHERE substr(payload, 1, 4) = ? AND needs_update = 0 ORDER BY seq",
                [.blob(SyncCrypto.pointerMagic)]
            ) { found.append(Self.parkedRecord($0)) }
            return found
        }
    }

    func parkedPointerCount() throws -> Int {
        try perform { database in
            var total = 0
            try database.query(
                "SELECT count(*) FROM parked WHERE substr(payload, 1, 4) = ? AND needs_update = 0", [.blob(SyncCrypto.pointerMagic)]
            ) { total = Int($0.int(0)) }
            return total
        }
    }

    func parkedCount() throws -> Int {
        try perform { database in
            var total = 0
            try database.query("SELECT count(*) FROM parked") { total = Int($0.int(0)) }
            return total
        }
    }

    func releaseHeld(entityIDs: [String]) throws {
        try perform { database in
            try database.transaction {
                for id in entityIDs {
                    try database.execute("DELETE FROM held WHERE entity_id = ?", [.text(id)])
                }
            }
        }
    }

    func heldCount() throws -> Int {
        try perform { database in
            var total = 0
            try database.query("SELECT count(*) FROM held") { total = Int($0.int(0)) }
            return total
        }
    }

    // MARK: Garbage collection

    func garbageCollectionLog() throws -> GarbageCollectionLog {
        try perform { database in
            func date(_ key: String) throws -> Date? {
                try Self.meta(key, in: database).flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            }
            return GarbageCollectionLog(
                lastStartedAt: try date("garbage_collection_started"), retryNotBefore: try date("garbage_collection_not_before"),
                lastAttemptAt: try date("garbage_collection_attempt"),
                lastOutcome: try Self.meta("garbage_collection_outcome", in: database).flatMap(GarbageCollectionOutcome.init(rawValue:)),
                quotaHitAt: try date("garbage_collection_quota_hit")
            )
        }
    }

    /// Notes an attempt at `date`. `retryAfter` is the server's rate limit; a started run clears any earlier one.
    func recordGarbageCollection(_ outcome: GarbageCollectionOutcome, at date: Date, retryAfter: TimeInterval? = nil) throws {
        try perform { database in
            try database.transaction {
                try Self.setMeta("garbage_collection_attempt", String(date.timeIntervalSince1970), in: database)
                try Self.setMeta("garbage_collection_outcome", outcome.rawValue, in: database)
                if outcome == .started {
                    // The server's worker may still end the run unfinished (stale); the client can't see that, so a started
                    // run counts as done and the week's wait begins.
                    try Self.setMeta("garbage_collection_started", String(date.timeIntervalSince1970), in: database)
                    try database.execute("DELETE FROM meta WHERE key = ?", [.text("garbage_collection_quota_hit")])
                    try database.execute("DELETE FROM meta WHERE key = ?", [.text("garbage_collection_not_before")])
                }
                if let retryAfter {
                    try Self.setMeta("garbage_collection_not_before", String(date.addingTimeInterval(retryAfter).timeIntervalSince1970), in: database)
                }
            }
        }
    }

    /// Notes that the server refused an upload for the storage limit; only the first since the last accepted run counts.
    func noteBlobQuotaHit(at date: Date) throws {
        try perform { database in
            if try Self.meta("garbage_collection_quota_hit", in: database) == nil {
                try Self.setMeta("garbage_collection_quota_hit", String(date.timeIntervalSince1970), in: database)
            }
        }
    }

    // MARK: Cursor and epoch

    /// The highest server seq pulled; 0 before the first pull.
    func cursor() throws -> Int64 {
        try perform { Int64(try Self.meta("cursor", in: $0) ?? "") ?? 0 }
    }

    func setCursor(_ seq: Int64) throws {
        try perform { try Self.setMeta("cursor", String(seq), in: $0) }
    }

    func epoch() throws -> Int64? {
        try perform { try Self.meta("epoch", in: $0).flatMap { Int64($0) } }
    }

    func setEpoch(_ epoch: Int64) throws {
        try perform { try Self.setMeta("epoch", String(epoch), in: $0) }
    }

    /// Forgets the cursor, every synced record, held record and the outbox, and the epoch.
    /// A reconcile must follow, or nothing is queued to push. The vault stays configured.
    func resetSyncProgress() throws {
        try perform { database in
            try database.transaction {
                try Self.clearContents(of: database)
                try database.execute("INSERT INTO meta(key, value) VALUES('vault_id', ?)", [.text(self.vaultID ?? "")])
            }
        }
    }

    // MARK: Internals

    private func perform<T>(_ work: (SQLiteDatabase) throws -> T) throws -> T {
        applyPending()
        return try execute(work)
    }

    private func execute<T>(_ work: (SQLiteDatabase) throws -> T) throws -> T {
        do {
            return try work(try open())
        } catch {
            Self.logger.error("Sync state operation failed: \(error)")
            if (error as? SQLiteError)?.isCorruption == true {
                database = nil
                removeFiles()
            }
            throw error
        }
    }

    private func applyPending() {
        let (wipeNeeded, queued) = gate.withLock { gate in
            defer {
                gate.wipeNeeded = false
                gate.pending.removeAll()
            }
            return (gate.wipeNeeded, gate.pending)
        }
        if wipeNeeded { wipe() }
        guard !queued.isEmpty else { return }
        do {
            try execute { database in
                try database.transaction {
                    for item in queued {
                        for entity in item.entities {
                            try database.execute(
                                """
                                INSERT INTO outbox(kind, id, generation, enqueued_at) VALUES(?, ?, 1, ?)
                                ON CONFLICT(kind, id) DO UPDATE SET generation = generation + 1
                                """,
                                [.text(entity.kind.rawValue), .text(entity.id), .double(item.at.timeIntervalSinceReferenceDate)]
                            )
                        }
                    }
                }
            }
        } catch {
            // `execute` logged it. Kept for the next call, unless sync was turned off meanwhile.
            gate.withLock {
                if $0.isEnabled { $0.pending.insert(contentsOf: queued, at: 0) }
            }
        }
    }

    private func wipe() {
        database = nil
        vaultID = nil
        removeFiles()
    }

    private func removeFiles() {
        guard case .file(let url) = location else { return }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Opens the database, recreating it empty if it is unusable. A file with no vault in it and none
    /// configured isn't a sync file: sync turns off and the file goes.
    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        let opened: SQLiteDatabase
        do {
            opened = try Self.openAndPrepare(location)
        } catch {
            let sqlite = error as? SQLiteError
            guard case .file = location, sqlite?.isCorruption == true || sqlite?.code == SQLITE_SCHEMA else {
                Self.logger.error("Sync state can't be opened, sync is off for this launch: \(error)")
                gate.withLock { $0.isEnabled = false }
                throw error
            }
            Self.logger.error("Sync state unusable, rebuilding: \(error)")
            removeFiles()
            opened = try Self.openAndPrepare(location)
        }
        let stored = try Self.meta("vault_id", in: opened).flatMap { $0.isEmpty ? nil : $0 }
        if let vaultID {
            if stored != vaultID {
                try opened.transaction {
                    try Self.clearContents(of: opened)
                    try Self.setMeta("vault_id", vaultID, in: opened)
                }
            }
        } else if let stored {
            vaultID = stored
        } else {
            gate.withLock { $0.isEnabled = false }
            removeFiles()
            throw Failure.notConfigured
        }
        database = opened
        return opened
    }

    private static func openAndPrepare(_ location: Location) throws -> SQLiteDatabase {
        let path: String
        switch location {
        case .inMemory:
            path = ":memory:"
        case .file(let url):
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = directory
            try excluded.setResourceValues(values)
            path = url.path
        }
        let database = try SQLiteDatabase(path: path)
        if case .file = location {
            try database.execute("PRAGMA journal_mode = WAL")
            try database.execute("PRAGMA synchronous = NORMAL")
        }
        var version: Int32 = 0
        try database.query("PRAGMA user_version") { version = Int32($0.int(0)) }
        if version == 0 {
            try database.transaction {
                try database.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try database.execute(
                    """
                    CREATE TABLE IF NOT EXISTS records(
                        record_key TEXT PRIMARY KEY, type TEXT NOT NULL, entity_id TEXT NOT NULL, seq INTEGER NOT NULL,
                        fingerprint TEXT NOT NULL, base_hash TEXT NOT NULL, base_content BLOB
                    )
                    """
                )
                try database.execute("CREATE INDEX IF NOT EXISTS records_by_entity ON records(type, entity_id)")
                try database.execute(
                    """
                    CREATE TABLE IF NOT EXISTS outbox(
                        kind TEXT NOT NULL, id TEXT NOT NULL, generation INTEGER NOT NULL, enqueued_at REAL NOT NULL,
                        PRIMARY KEY(kind, id)
                    )
                    """
                )
                try database.execute("PRAGMA user_version = \(schemaVersion)")
            }
        } else if version != schemaVersion {
            throw SQLiteError(code: SQLITE_SCHEMA, message: "sync state schema version \(version)")
        }
        // Tables added after the first version; a file of an older schema never gets here (it is rebuilt above, being derived state).
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS held(
                record_key TEXT PRIMARY KEY, type TEXT NOT NULL, entity_id TEXT NOT NULL, seq INTEGER NOT NULL, payload BLOB NOT NULL,
                blocked INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS parked(
                record_key TEXT PRIMARY KEY, seq INTEGER NOT NULL, payload BLOB NOT NULL, deleted INTEGER NOT NULL,
                needs_update INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try database.execute("CREATE TABLE IF NOT EXISTS attempts(record_key TEXT PRIMARY KEY, entity_id TEXT NOT NULL DEFAULT '', base_hash TEXT NOT NULL, content BLOB NOT NULL)")
        try database.execute("CREATE INDEX IF NOT EXISTS held_by_entity ON held(entity_id)")
        try database.query("SELECT count(*) FROM meta") { _ in }
        try database.query("SELECT count(*) FROM records") { _ in }
        try database.query("SELECT count(*) FROM outbox") { _ in }
        return database
    }

    private static func clearContents(of database: SQLiteDatabase) throws {
        try database.execute("DELETE FROM records")
        try database.execute("DELETE FROM attempts")
        try database.execute("DELETE FROM held")
        try database.execute("DELETE FROM parked")
        try database.execute("DELETE FROM outbox")
        try database.execute("DELETE FROM meta")
    }

    private static func write(_ record: SyncedRecord, in database: SQLiteDatabase) throws {
        try database.execute("DELETE FROM attempts WHERE record_key = ?", [.text(record.recordKey)])
        try database.execute(
            "INSERT OR REPLACE INTO records(record_key, type, entity_id, seq, fingerprint, base_hash, base_content) VALUES(?, ?, ?, ?, ?, ?, ?)",
            [
                .text(record.recordKey), .text(record.type.rawValue), .text(record.entityID), .int(record.seq),
                .text(record.fingerprint), .text(record.baseHash), .blob(record.baseContent),
            ]
        )
    }

    private static func meta(_ key: String, in database: SQLiteDatabase) throws -> String? {
        var found: String?
        try database.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { found = $0.text(0) }
        return found
    }

    private static func setMeta(_ key: String, _ value: String, in database: SQLiteDatabase) throws {
        try database.execute("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text(key), .text(value)])
    }
}

#if DEBUG
extension SyncState {
    /// Sync has no UI yet: launching with `THOUGHTREPS_SYNC_VAULT=<id>` turns it on for that vault.
    func enableForDebugging() async {
        guard let vault = ProcessInfo.processInfo.environment["THOUGHTREPS_SYNC_VAULT"], !vault.isEmpty else { return }
        do {
            try configure(vaultID: vault)
        } catch {
            Self.logger.error("Enabling sync failed: \(error)")
        }
    }
}
#endif
