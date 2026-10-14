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

struct OutboxEntry: Sendable, Equatable {
    var entity: SyncEntity
    /// Bumped by every enqueue of the same entity; `markSynced` dequeues only the generation it pushed.
    var generation: Int64
    var enqueuedAt: Date
}

/// What sync knows about this device's copy of the library, in a SQLite file of its own beside the
/// SwiftData store: the pull cursor, the outbox of entities to push, and what was last synced for each
/// record. Derived data, never the source of truth: if the file is lost, `SyncReconciler` queues
/// everything again and the engine does a full resync.
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

    private static let schemaVersion: Int32 = 1
    private static let logger = Logger(subsystem: "com.thoughtreps", category: "sync")

    private struct Queued: Sendable {
        var entities: [SyncEntity]
        var at: Date
    }

    private struct Gate {
        var isEnabled: Bool
        var pending: [Queued] = []
        var wipeNeeded = false
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
        if accepted { Task { await self.flush() } }
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
                    try database.execute(
                        "INSERT OR REPLACE INTO records(record_key, type, entity_id, seq, fingerprint, base_hash, base_content) VALUES(?, ?, ?, ?, ?, ?, ?)",
                        [
                            .text(record.recordKey), .text(record.type.rawValue), .text(record.entityID), .int(record.seq),
                            .text(record.fingerprint), .text(record.baseHash), .blob(record.baseContent),
                        ]
                    )
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

    /// Forgets the cursor, epoch, every synced record and the outbox. A reconcile must follow, or nothing
    /// is queued to push. The vault stays configured.
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
        try database.query("SELECT count(*) FROM meta") { _ in }
        try database.query("SELECT count(*) FROM records") { _ in }
        try database.query("SELECT count(*) FROM outbox") { _ in }
        return database
    }

    private static func clearContents(of database: SQLiteDatabase) throws {
        try database.execute("DELETE FROM records")
        try database.execute("DELETE FROM outbox")
        try database.execute("DELETE FROM meta")
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
