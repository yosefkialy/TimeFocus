import Foundation
import SQLite3

public enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null

    public static func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    public static func opt(_ i: Int64?) -> SQLValue { i.map { .int($0) } ?? .null }
    public static func opt(_ d: Double?) -> SQLValue { d.map { .double($0) } ?? .null }
    public static func opt(_ b: Data?) -> SQLValue { b.map { .blob($0) } ?? .null }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A prepared statement bound to one connection.
public final class SQLStatement {
    let stmt: OpaquePointer
    unowned let db: SQLiteDB

    init(stmt: OpaquePointer, db: SQLiteDB) { self.stmt = stmt; self.db = db }
    deinit { sqlite3_finalize(stmt) }

    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case .int(let x): rc = sqlite3_bind_int64(stmt, idx, x)
            case .double(let x): rc = sqlite3_bind_double(stmt, idx, x)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                rc = d.withUnsafeBytes { p in sqlite3_bind_blob(stmt, idx, p.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            if rc != SQLITE_OK { throw db.error(rc) }
        }
    }

    /// Returns true while a row is available.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw db.error(rc)
    }

    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func intOpt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func doubleOpt(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    public func text(_ i: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: p)
    }
    public func textOpt(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
    public func blob(_ i: Int32) -> Data? {
        guard !isNull(i), let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
}

/// Minimal SQLite connection wrapper. One connection per subsystem; WAL mode allows concurrent readers.
/// A connection must be used from one thread (or serial queue) at a time.
public final class SQLiteDB {
    let handle: OpaquePointer
    private var cache: [String: SQLStatement] = [:]

    public init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let handle = h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h { sqlite3_close(h) }
            throw SQLiteError(code: rc, message: msg)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 8000)
        try script("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY;")
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    func error(_ rc: Int32) -> SQLiteError { SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle))) }

    /// Runs a script of one or more `;`-separated statements (no parameters, no result rows).
    public func script(_ sql: String) throws {
        var remaining = sql
        while !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var st: OpaquePointer?
            var consumed = 0
            let rc: Int32 = remaining.withCString { base in
                var tail: UnsafePointer<CChar>?
                let rc = sqlite3_prepare_v2(handle, base, -1, &st, &tail)
                if let tail { consumed = base.distance(to: tail) }
                return rc
            }
            guard rc == SQLITE_OK else { throw error(rc) }
            if let st {
                defer { sqlite3_finalize(st) }
                var r = sqlite3_step(st)
                while r == SQLITE_ROW { r = sqlite3_step(st) }
                guard r == SQLITE_DONE else { throw error(r) }
            }
            guard consumed > 0 else { break }
            let utf8 = Array(remaining.utf8)
            remaining = String(decoding: utf8[min(consumed, utf8.count)...], as: UTF8.self)
        }
    }

    private func statement(_ sql: String) throws -> SQLStatement {
        if let s = cache[sql] { return s }
        if cache.count >= 160 { cache.removeAll() } // bound memory even if a caller builds SQL dynamically
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &st, nil)
        guard rc == SQLITE_OK, let st else { throw error(rc) }
        let s = SQLStatement(stmt: st, db: self)
        cache[sql] = s
        return s
    }

    /// Executes a statement that returns no rows.
    public func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let s = try statement(sql)
        try s.bind(args)
        while try s.step() {}
        sqlite3_reset(s.stmt)
    }

    /// Executes a query and maps each row.
    public func query<T>(_ sql: String, _ args: [SQLValue] = [], _ map: (SQLStatement) throws -> T) throws -> [T] {
        let s = try statement(sql)
        try s.bind(args)
        var out: [T] = []
        while try s.step() { out.append(try map(s)) }
        sqlite3_reset(s.stmt)
        return out
    }

    public func scalar(_ sql: String, _ args: [SQLValue] = []) throws -> Double? {
        try query(sql, args) { $0.doubleOpt(0) }.first ?? nil
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try run("COMMIT")
            return r
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }
}
