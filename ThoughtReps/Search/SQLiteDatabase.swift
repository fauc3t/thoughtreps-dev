import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite error \(code): \(message)" }

    /// The file is damaged or isn't a database; only deleting and rebuilding it helps.
    var isCorruption: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
}

enum SQLiteValue {
    case text(String)
    case double(Double)
    case int(Int64)
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func text(_ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
}

/// A thin wrapper over one SQLite connection. Not thread-safe: the owner (`SearchIndex`) is an
/// actor, and the connection is closed when this object is released.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard code == SQLITE_OK else {
            let error = SQLiteError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close_v2(handle)
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String, _ binds: [SQLiteValue] = []) throws {
        try query(sql, binds) { _ in }
    }

    /// Runs `sql`, calling `row` for each result row.
    func query(_ sql: String, _ binds: [SQLiteValue] = [], row: (SQLiteRow) throws -> Void) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK, let statement else { throw lastError(prepared) }

        for (index, value) in binds.enumerated() {
            let position = Int32(index + 1)
            let code: Int32
            switch value {
            case .text(let text): code = sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .double(let number): code = sqlite3_bind_double(statement, position, number)
            case .int(let number): code = sqlite3_bind_int64(statement, position, number)
            }
            guard code == SQLITE_OK else { throw lastError(code) }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw lastError(step) }
            try row(SQLiteRow(statement: statement))
        }
    }

    var lastInsertedRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func lastError(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
