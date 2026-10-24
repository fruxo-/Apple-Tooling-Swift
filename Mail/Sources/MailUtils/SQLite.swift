import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue {
    case int(Int64)
    case text(String)
    case null
}

struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int64(_ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    func string(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: text)
    }
}

final class SQLiteConnection {
    private var db: OpaquePointer?

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw ExportError.database("Could not open \(path): \(message)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(db))
    }

    /// Runs `sql` with 1-based positional bindings (`?1`, `?2`, …) and calls `body` for every row.
    func forEachRow(_ sql: String,
                    _ bindings: [SQLiteValue] = [],
                    _ body: (SQLiteRow) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ExportError.database("SQL error: \(lastError)\n\(sql)")
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in bindings.enumerated() {
            let position = Int32(offset + 1)
            switch value {
            case .int(let number):
                sqlite3_bind_int64(statement, position, number)
            case .text(let text):
                sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
            case .null:
                sqlite3_bind_null(statement, position)
            }
        }

        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                try body(SQLiteRow(statement: statement!))
            } else if code == SQLITE_DONE {
                break
            } else {
                throw ExportError.database("SQL error while reading rows: \(lastError)")
            }
        }
    }
}

/// A private copy of the Envelope Index (plus its -wal/-shm files) in a temp directory,
/// so we never open, lock or checkpoint the database Mail is using.
struct DatabaseSnapshot {
    let directory: URL
    let databaseURL: URL

    static func make(from source: URL) throws -> DatabaseSnapshot {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("mailexport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            for suffix in ["", "-wal", "-shm"] {
                let original = URL(fileURLWithPath: source.path + suffix)
                guard fileManager.fileExists(atPath: original.path) else { continue }
                try fileManager.copyItem(
                    at: original,
                    to: directory.appendingPathComponent(source.lastPathComponent + suffix)
                )
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        return DatabaseSnapshot(
            directory: directory,
            databaseURL: directory.appendingPathComponent(source.lastPathComponent)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
