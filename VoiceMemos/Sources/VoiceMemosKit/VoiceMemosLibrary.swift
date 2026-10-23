import Foundation
import SQLite3

public struct Recording: Sendable, Equatable {
    public let date: Date
    /// The title shown in Voice Memos; empty if the recording has none.
    /// Read from `ZENCRYPTEDTITLE` (macOS Sonoma+), falling back to `ZCUSTOMLABEL`.
    public let title: String
    public let audioURL: URL

    public init(date: Date, title: String, audioURL: URL) {
        self.date = date
        self.title = title
        self.audioURL = audioURL
    }

    /// `false` when the audio isn't on disk, e.g. evicted to iCloud.
    public var audioFileExists: Bool {
        FileManager.default.fileExists(atPath: audioURL.path)
    }

    /// The recording's logical name: the title the user sees (and can edit) in Voice Memos.
    /// Falls back to the audio file's base name when the recording has no title.
    public var displayName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? audioURL.deletingPathExtension().lastPathComponent : trimmed
    }
}

public enum VoiceMemosError: Error, LocalizedError, CustomStringConvertible {
    case databaseNotFound(path: String)
    case cannotCopyDatabase(path: String, reason: String)
    case sqlite(message: String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path):
            return "Database not found at \(path). Use --db to point at CloudRecordings.db."
        case .cannotCopyDatabase(let path, let reason):
            return """
                Couldn't read the Voice Memos database at \(path): \(reason)
                Grant your terminal Full Disk Access in System Settings > Privacy & Security.
                """
        case .sqlite(let message):
            return "SQLite error: \(message)"
        }
    }

    public var description: String { errorDescription ?? "Voice Memos error" }
}

public struct VoiceMemosLibrary: Sendable {
    /// Location used by macOS Sonoma (14) and later.
    public static var defaultDatabaseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db"
            )
    }

    public let databaseURL: URL

    public init(databaseURL: URL = VoiceMemosLibrary.defaultDatabaseURL) {
        self.databaseURL = databaseURL
    }

    /// Returns all recordings matching `criteria`, oldest first.
    ///
    /// The database (and its `-wal` / `-shm` sidecars) is copied to a temporary
    /// directory and queried there, so the live files are never touched or locked and
    /// recent writes still sitting in the WAL are visible.
    public func search(_ criteria: SearchCriteria, calendar: Calendar = .current) throws -> [Recording] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: databaseURL.path) else {
            throw VoiceMemosError.databaseNotFound(path: databaseURL.path)
        }

        let workDir = fm.temporaryDirectory
            .appendingPathComponent("voicememos-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let copy = workDir.appendingPathComponent("CloudRecordings.db")
        do {
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: databaseURL.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        } catch {
            throw VoiceMemosError.cannotCopyDatabase(
                path: databaseURL.path, reason: error.localizedDescription)
        }

        let bounds = criteria.date.bounds(calendar: calendar)
        let rows = try Self.fetchRows(databasePath: copy.path, start: bounds.start, end: bounds.end)
        let recordingsDirectory = databaseURL.deletingLastPathComponent()

        return rows.compactMap { row in
            // Keyword matching happens here rather than in SQL: LIKE is only
            // case-insensitive for ASCII and knows nothing about diacritics.
            guard criteria.titleExpression?.matches(row.title) ?? true else { return nil }

            // ZPATH is normally absolute; resolve relative values against the DB folder.
            let audioURL = row.path.hasPrefix("/")
                ? URL(fileURLWithPath: row.path)
                : recordingsDirectory.appendingPathComponent(row.path)
            return Recording(date: row.date, title: row.title, audioURL: audioURL)
        }
    }

    // MARK: - SQLite

    private struct Row {
        let date: Date
        let title: String
        let path: String
    }

    private static func fetchRows(databasePath: String, start: Date?, end: Date?) throws -> [Row] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "couldn't open database"
            sqlite3_close(db)
            throw VoiceMemosError.sqlite(message: message)
        }
        defer { sqlite3_close(db) }

        // ZDATE is a Core Data timestamp: seconds since 2001-01-01 00:00:00 UTC,
        // i.e. exactly `Date.timeIntervalSinceReferenceDate`.
        //
        // The title: since iOS 17 / macOS Sonoma, Voice Memos keeps the user-visible title in
        // ZENCRYPTEDTITLE (the name refers to how it's stored in iCloud; locally it is
        // plaintext). ZCUSTOMLABEL is the older column, so it's only a fallback.
        var sql = """
            SELECT ZDATE, COALESCE(NULLIF(ZENCRYPTEDTITLE, ''), ZCUSTOMLABEL), ZPATH
            FROM ZCLOUDRECORDING
            WHERE ZPATH IS NOT NULL
            """
        var bindings: [Double] = []
        if let start {
            sql += " AND ZDATE >= ?"
            bindings.append(start.timeIntervalSinceReferenceDate)
        }
        if let end {
            sql += " AND ZDATE < ?"
            bindings.append(end.timeIntervalSinceReferenceDate)
        }
        sql += " ORDER BY ZDATE ASC"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VoiceMemosError.sqlite(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            sqlite3_bind_double(statement, Int32(index + 1), value)
        }

        var rows: [Row] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let path = text(statement, column: 2) {
                rows.append(
                    Row(
                        date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 0)),
                        title: text(statement, column: 1) ?? "",
                        path: path
                    )
                )
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw VoiceMemosError.sqlite(message: String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }

    private static func text(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
            let cString = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: cString)
    }
}