import Foundation
import SQLite3

public enum SQLValue: Equatable {
    case null, int(Int64), double(Double), text(String), blob(Data)

    public var int: Int64? { if case .int(let v) = self { return v }; if case .double(let d) = self { return Int64(d) }; return nil }
    public var double: Double? { if case .double(let v) = self { return v }; if case .int(let i) = self { return Double(i) }; return nil }
    public var text: String? { if case .text(let v) = self { return v }; return nil }
    public var blob: Data? { if case .blob(let v) = self { return v }; return nil }
    public var isNull: Bool { self == .null }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "SQLite: \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper. Not thread-safe by itself; callers serialize access.
public final class SQLiteDB {
    let handle: OpaquePointer

    public init(path: String, readOnly: Bool = false) throws {
        var h: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &h, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h { sqlite3_close(h) }
            throw SQLiteError(message: "\(msg) (\(path))")
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
    }

    deinit { sqlite3_close(handle) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [Any?] = []) throws -> Int {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw SQLiteError(message: errmsg) }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ params: [Any?] = []) throws -> [[String: SQLValue]] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: errmsg) }
            var row: [String: SQLValue] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i), n > 0 { row[name] = .blob(Data(bytes: p, count: n)) } else { row[name] = .blob(Data()) }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    public func columns(of table: String) throws -> Set<String> {
        Set(try query("PRAGMA table_info(\(table))").compactMap { $0["name"]?.text })
    }

    public func tables() throws -> [String] {
        try query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0["name"]?.text }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let r = try body(); try exec("COMMIT"); return r } catch { try? exec("ROLLBACK"); throw error }
    }

    private var errmsg: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: "\(errmsg) in: \(sql)")
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            case let v as Date: sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            default: sqlite3_bind_text(stmt, idx, "\(p!)", -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }
}
