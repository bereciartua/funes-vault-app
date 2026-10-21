import Foundation
import SQLite3

/// A SQLite failure: the result code and SQLite's message (never row contents).
struct SQLiteError: Error, Sendable, CustomStringConvertible {
    var code: Int32
    var message: String
    var description: String { "SQLite \(code): \(message)" }
}

/// One connection to a SQLite file, used for one operation and then closed. The capture queue
/// lives in the App Group container, shared with the extensions, and iOS kills a suspended app
/// that still holds a lock on a file there (`0xdead10cc`). Opening per operation, with the
/// default rollback journal, means no lock outlives a call.
final class SQLiteConnection {
    private var db: OpaquePointer?

    init(path: String) throws(SQLiteError) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK else {
            let error = SQLiteError(code: result, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close(db)
            db = nil
            throw error
        }
        // Another process (the share extension, an App Intent) may be writing: wait for it.
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws(SQLiteError) {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw error(result) }
    }

    /// Runs `body` in a `BEGIN IMMEDIATE` transaction, so a count and an insert are atomic across
    /// processes.
    func transaction<T>(_ body: () throws(SQLiteError) -> T) throws(SQLiteError) -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Runs a statement with `bindings`, calling `row` for each result row.
    func run(_ sql: String, _ bindings: [SQLiteValue] = [], row: ((SQLiteRow) -> Void)? = nil) throws(SQLiteError) {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw error(prepared) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            let bound: Int32 = switch value {
            case .null: sqlite3_bind_null(statement, position)
            case let .int(int): sqlite3_bind_int64(statement, position, int)
            case let .double(double): sqlite3_bind_double(statement, position, double)
            case let .text(text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            }
            guard bound == SQLITE_OK else { throw error(bound) }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw error(step) }
            row?(SQLiteRow(statement: statement))
        }
    }

    func scalar(_ sql: String, _ bindings: [SQLiteValue] = []) throws(SQLiteError) -> Int64 {
        var value: Int64 = 0
        try run(sql, bindings) { value = $0.int(0) }
        return value
    }

    /// Rows changed by the last statement.
    var changes: Int { Int(sqlite3_changes(db)) }

    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    init(_ text: String?) { self = text.map(SQLiteValue.text) ?? .null }
    init(_ date: Date?) { self = date.map { .double($0.timeIntervalSince1970) } ?? .null }
}

/// The current row of a running statement.
struct SQLiteRow {
    let statement: OpaquePointer?

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
    func date(_ column: Int32) -> Date? { isNull(column) ? nil : Date(timeIntervalSince1970: double(column)) }
}
