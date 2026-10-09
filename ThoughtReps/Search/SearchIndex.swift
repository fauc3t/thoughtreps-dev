import Foundation
import SQLite3
import os

/// A fingerprint of one indexed thought; see `SearchDocument`.
struct SearchIndexEntry: Sendable, Equatable {
    var updatedAt: Date
    var isArchived: Bool
}

/// Full-text index over the thoughts, in a SQLite FTS5 file of its own beside the SwiftData store.
///
/// It is derived data: SwiftData stays the source of truth, `ThoughtStore` keeps the index in step
/// after each write, and `SearchIndexStatus.reconcile` repairs any drift at launch. A file that is
/// missing, damaged or from another schema version is deleted and rebuilt.
///
/// Writes arrive through `submit`, which can be called from any thread without waiting. Changes
/// are applied in the order submitted, and every other method applies the ones still queued first,
/// so a search sees every write that was submitted before it.
actor SearchIndex {
    enum Location: Sendable {
        case file(URL)
        case inMemory
    }

    enum Change: Sendable {
        case upsert(SearchDocument)
        /// Only the fingerprint changed (archive, restore, interval edits), so the text needn't be re-read.
        case setFingerprint(UUID, updatedAt: Date, isArchived: Bool)
        case remove(UUID)
        case removeAll
    }

    /// The app's index, in Application Support, opened on first use. Under tests, previews and
    /// screenshot mode it is in memory, so they never touch the real file.
    static let shared = SearchIndex(location: isRunningTestsOrPreviews ? .inMemory : .file(defaultFileURL))

    static var isRunningTestsOrPreviews: Bool {
        #if DEBUG
        if ScreenshotMode.isActive { return true }
        #endif
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
    }

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Search", directoryHint: .isDirectory).appending(path: "search-index.sqlite")
    }

    private static let schemaVersion: Int32 = 1
    private static let logger = Logger(subsystem: "com.thoughtreps", category: "search")

    nonisolated let location: Location
    private var database: SQLiteDatabase?
    private nonisolated let queue = OSAllocatedUnfairLock(initialState: [Change]())

    init(location: Location) {
        self.location = location
    }

    // MARK: Writing

    /// Queues a change and returns at once; the actor applies it shortly after.
    nonisolated func submit(_ change: Change) {
        queue.withLock { $0.append(change) }
        Task { await self.applyQueued() }
    }

    /// Returns once everything submitted so far is applied.
    func flush() {
        applyQueued()
    }

    /// Adds or replaces `documents`.
    func upsert(_ documents: [SearchDocument]) {
        applyQueued()
        perform { database in
            try database.transaction {
                for document in documents { try Self.write(document, in: database) }
            }
        }
    }

    /// Adds or replaces each document only if the row's fingerprint is still `expected` (nil: no
    /// row). Reconciliation uses this so a write made since its scan isn't overwritten.
    func upsert(_ documents: [(SearchDocument, expected: SearchIndexEntry?)]) {
        applyQueued()
        perform { database in
            try database.transaction {
                for (document, expected) in documents where try Self.entry(for: document.id, in: database) == expected {
                    try Self.write(document, in: database)
                }
            }
        }
    }

    func remove(ids: [UUID]) {
        applyQueued()
        perform { database in
            try database.transaction {
                for id in ids { try Self.delete(id, in: database) }
            }
        }
    }

    /// Removes each row only if its fingerprint is still the one given. Returns how many were removed.
    func remove(_ rows: [(UUID, SearchIndexEntry)]) -> Int {
        applyQueued()
        var removed = 0
        perform { database in
            try database.transaction {
                for (id, expected) in rows where try Self.entry(for: id, in: database) == expected {
                    try Self.delete(id, in: database)
                    removed += 1
                }
            }
        }
        return removed
    }

    // MARK: Reading

    /// Thoughts matching every word of `input` (each as a prefix), best match first and newer
    /// first among equals. Empty when `input` has no searchable word.
    func search(_ input: String, scope: SearchScope = .active, limit: Int = 50, offset: Int = 0) throws -> [SearchResult] {
        guard let match = SearchQuery.matchExpression(for: input), limit > 0 else { return [] }
        applyQueued()
        let database = try open()
        do {
            return try Self.search(match: match, scope: scope, limit: limit, offset: max(0, offset), in: database)
        } catch let error as SQLiteError where error.isCorruption {
            reset()
            throw error
        }
    }

    /// Every indexed thought's fingerprint.
    func entries() -> [UUID: SearchIndexEntry] {
        applyQueued()
        var result: [UUID: SearchIndexEntry] = [:]
        perform { database in
            try database.query("SELECT id, updated_at, archived FROM thought_meta") { row in
                guard let id = UUID(uuidString: row.text(0)) else { return }
                result[id] = SearchIndexEntry(updatedAt: Date(timeIntervalSinceReferenceDate: row.double(1)), isArchived: row.int(2) != 0)
            }
        }
        return result
    }

    /// The stored text of one thought, as `SearchDocument` would produce it. For checks and tests.
    func document(for id: UUID) -> SearchDocument? {
        applyQueued()
        var found: SearchDocument?
        perform { database in
            try database.query(
                """
                SELECT m.updated_at, m.archived, f.body, f.blocks, f.titles, f.tags
                FROM thought_meta m JOIN thought_fts f ON f.rowid = m.rowid WHERE m.id = ?
                """,
                [.text(id.uuidString)]
            ) { row in
                found = SearchDocument(
                    id: id, updatedAt: Date(timeIntervalSinceReferenceDate: row.double(0)), isArchived: row.int(1) != 0,
                    body: row.text(2), blocks: row.text(3), titles: row.text(4), tags: row.text(5)
                )
            }
        }
        return found
    }

    var count: Int {
        applyQueued()
        var total = 0
        perform { database in
            try database.query("SELECT count(*) FROM thought_meta") { total = Int($0.int(0)) }
        }
        return total
    }

    // MARK: Internals

    private func applyQueued() {
        let changes = queue.withLock { pending in
            defer { pending.removeAll() }
            return pending
        }
        guard !changes.isEmpty else { return }
        perform { database in
            try database.transaction {
                for change in changes {
                    switch change {
                    case .upsert(let document): try Self.write(document, in: database)
                    case .setFingerprint(let id, let updatedAt, let archived):
                        try database.execute(
                            "UPDATE thought_meta SET updated_at = ?, archived = ? WHERE id = ?",
                            [.double(updatedAt.timeIntervalSinceReferenceDate), .int(archived ? 1 : 0), .text(id.uuidString)]
                        )
                    case .remove(let id): try Self.delete(id, in: database)
                    case .removeAll:
                        try database.execute("DELETE FROM thought_fts")
                        try database.execute("DELETE FROM thought_meta")
                    }
                }
            }
        }
    }

    /// Runs a write or read that can fail without the caller caring: the index is repaired at the
    /// next launch, and a damaged file is deleted so it can be rebuilt.
    private func perform(_ work: (SQLiteDatabase) throws -> Void) {
        do {
            try work(try open())
        } catch {
            // Not retried: the row stays wrong (or the whole index, after a reset) until the next launch's reconciliation.
            Self.logger.error("Search index operation failed: \(error)")
            if (error as? SQLiteError)?.isCorruption == true { reset() }
        }
    }

    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        do {
            database = try Self.openAndPrepare(location)
        } catch {
            guard case .file = location else { throw error }
            Self.logger.error("Search index unusable, rebuilding: \(error)")
            removeFiles()
            database = try Self.openAndPrepare(location)
        }
        return database!
    }

    /// Drops the file; the next use creates an empty one. Nothing refills it until the next launch's reconciliation, so search is incomplete until then.
    private func reset() {
        database = nil
        removeFiles()
    }

    private func removeFiles() {
        guard case .file(let url) = location else { return }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
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
                try database.execute("CREATE TABLE IF NOT EXISTS thought_meta(id TEXT PRIMARY KEY, updated_at REAL NOT NULL, archived INTEGER NOT NULL)")
                try database.execute(
                    """
                    CREATE VIRTUAL TABLE IF NOT EXISTS thought_fts USING fts5(
                        body, blocks, titles, tags,
                        tokenize = 'unicode61 remove_diacritics 2', prefix = '1 2 3'
                    )
                    """
                )
                try database.execute("PRAGMA user_version = \(schemaVersion)")
            }
        } else if version != schemaVersion {
            throw SQLiteError(code: SQLITE_SCHEMA, message: "search index schema version \(version)")
        }
        try database.query("SELECT count(*) FROM thought_meta") { _ in }
        try database.query("SELECT rowid FROM thought_fts LIMIT 1") { _ in }
        return database
    }

    private static func entry(for id: UUID, in database: SQLiteDatabase) throws -> SearchIndexEntry? {
        var found: SearchIndexEntry?
        try database.query("SELECT updated_at, archived FROM thought_meta WHERE id = ?", [.text(id.uuidString)]) { row in
            found = SearchIndexEntry(updatedAt: Date(timeIntervalSinceReferenceDate: row.double(0)), isArchived: row.int(1) != 0)
        }
        return found
    }

    private static func storedRowID(of id: UUID, in database: SQLiteDatabase) throws -> Int64? {
        var found: Int64?
        try database.query("SELECT rowid FROM thought_meta WHERE id = ?", [.text(id.uuidString)]) { found = $0.int(0) }
        return found
    }

    private static func write(_ document: SearchDocument, in database: SQLiteDatabase) throws {
        let archived = SQLiteValue.int(document.isArchived ? 1 : 0)
        let updated = SQLiteValue.double(document.updatedAt.timeIntervalSinceReferenceDate)
        let rowID: Int64
        if let existing = try storedRowID(of: document.id, in: database) {
            rowID = existing
            try database.execute("UPDATE thought_meta SET updated_at = ?, archived = ? WHERE rowid = ?", [updated, archived, .int(rowID)])
            try database.execute("DELETE FROM thought_fts WHERE rowid = ?", [.int(rowID)])
        } else {
            try database.execute("INSERT INTO thought_meta(id, updated_at, archived) VALUES(?, ?, ?)", [.text(document.id.uuidString), updated, archived])
            rowID = database.lastInsertedRowID
        }
        try database.execute(
            "INSERT INTO thought_fts(rowid, body, blocks, titles, tags) VALUES(?, ?, ?, ?, ?)",
            [.int(rowID), .text(document.body), .text(document.blocks), .text(document.titles), .text(document.tags)]
        )
    }

    private static func delete(_ id: UUID, in database: SQLiteDatabase) throws {
        guard let rowID = try storedRowID(of: id, in: database) else { return }
        try database.execute("DELETE FROM thought_fts WHERE rowid = ?", [.int(rowID)])
        try database.execute("DELETE FROM thought_meta WHERE rowid = ?", [.int(rowID)])
    }

    private static func search(match: String, scope: SearchScope, limit: Int, offset: Int, in database: SQLiteDatabase) throws -> [SearchResult] {
        let scopeClause: String
        switch scope {
        case .active: scopeClause = "AND m.archived = 0"
        case .archived: scopeClause = "AND m.archived = 1"
        case .all: scopeClause = ""
        }
        struct Hit {
            let rowID: Int64
            let id: UUID
            let isArchived: Bool
        }
        var hits: [Hit] = []
        try database.query(
            """
            SELECT m.rowid, m.id, m.archived
            FROM thought_fts JOIN thought_meta m ON m.rowid = thought_fts.rowid
            WHERE thought_fts MATCH ? \(scopeClause)
            ORDER BY bm25(thought_fts, 1.0, 1.0, 2.0, 2.0), m.updated_at DESC
            LIMIT ? OFFSET ?
            """,
            [.text(match), .int(Int64(limit)), .int(Int64(offset))]
        ) { row in
            guard let id = UUID(uuidString: row.text(1)) else { return }
            hits.append(Hit(rowID: row.int(0), id: id, isArchived: row.int(2) != 0))
        }
        guard !hits.isEmpty else { return [] }

        // Snippets are built for the page only: computing them in the ranking query would do it for every match.
        let start = String(SearchSnippet.matchStart), end = String(SearchSnippet.matchEnd)
        let columns = (0..<4).map { "snippet(thought_fts, \($0), '\(start)', '\(end)', '…', 14)" }.joined(separator: ", ")
        var snippets: [Int64: [String]] = [:]
        try database.query(
            "SELECT rowid, \(columns) FROM thought_fts WHERE thought_fts MATCH ? AND rowid IN (\(hits.map { String($0.rowID) }.joined(separator: ",")))",
            [.text(match)]
        ) { row in
            snippets[row.int(0)] = (1...4).map { row.text(Int32($0)) }
        }

        let fields: [SearchField] = [.body, .blockText, .blockTitle, .tag]
        return hits.map { hit in
            let candidates = snippets[hit.rowID] ?? []
            let index = candidates.firstIndex { $0.contains(SearchSnippet.matchStart) } ?? 0
            let text = candidates.indices.contains(index) ? candidates[index] : ""
            var result = SearchResult(id: hit.id, isArchived: hit.isArchived, matchedField: fields[index], snippet: SearchSnippet.singleLine(text))
            if index == 0 {
                result.bodySnippet = text
                result.otherMatch = candidates.indices.dropFirst().first { candidates[$0].contains(SearchSnippet.matchStart) }
                    .map { SearchResult.Other(field: fields[$0], snippet: SearchSnippet.singleLine(candidates[$0])) }
            }
            return result
        }
    }
}
