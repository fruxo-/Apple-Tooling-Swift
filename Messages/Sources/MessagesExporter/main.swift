import CSQLite
import Foundation

private let appleEpochSeconds = 978_307_200.0

private enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var string: String? {
        if case .text(let value) = self { return value }
        return nil
    }
    var integer: Int64? {
        if case .integer(let value) = self { return value }
        if case .real(let value) = self { return Int64(exactly: value) }
        return nil
    }
    var number: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        default: return nil
        }
    }
}

private struct SQLiteRow {
    let values: [String: SQLiteValue]
    subscript(_ key: String) -> SQLiteValue { values[key] ?? .null }
}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: URL) throws {
        let result = sqlite3_open_v2(
            path.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let reason =
                handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle { sqlite3_close(handle) }
            self.handle = nil
            throw ToolError.message(reason)
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func rows(_ sql: String, bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        guard let handle else { throw ToolError.message("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else {
            throw ToolError.message(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let number):
                result = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                result = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                result = string.withCString {
                    sqlite3_bind_text(
                        statement, index, $0, -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement, index, bytes.baseAddress, Int32(data.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
            guard result == SQLITE_OK else {
                throw ToolError.message(String(cString: sqlite3_errmsg(handle)))
            }
        }

        var resultRows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw ToolError.message(String(cString: sqlite3_errmsg(handle)))
            }
            var values: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    values[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT:
                    values[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let pointer = sqlite3_column_text(statement, index) {
                        values[name] = .text(
                            String(
                                decoding: UnsafeBufferPointer(start: pointer, count: count),
                                as: UTF8.self))
                    } else {
                        values[name] = .null
                    }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if let pointer = sqlite3_column_blob(statement, index) {
                        values[name] = .blob(Data(bytes: pointer, count: count))
                    } else {
                        values[name] = .blob(Data())
                    }
                default:
                    values[name] = .null
                }
            }
            resultRows.append(SQLiteRow(values: values))
        }
        return resultRows
    }
}

private enum ToolError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

private struct Options {
    var database: String?
    var output = "messages_export"
    var me = "Me"
    var oldestFirst = false
}

private func usage() -> String {
    """
    Usage: messages-exporter [DB] [--out DIR] [--me NAME] [--oldest-first]
    Export Messages conversations to separate text files.
      DB               path to chat.db (auto-detected if omitted)
      --out DIR        output directory (default: ./messages_export)
      --me NAME        label for your own messages (default: Me)
      --oldest-first   sort oldest to newest instead of newest first
      -h, --help       show this help
    """
}

private func parseArguments() throws -> Options {
    var database: String?
    var output = "messages_export"
    var me = "Me"
    var oldestFirst = false
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "-h", "--help":
            print(usage())
            exit(0)
        case "--out", "--me":
            guard !args.isEmpty else { throw ToolError.message("missing value for \(arg)") }
            let value = args.removeFirst()
            if arg == "--out" { output = value } else { me = value }
        case "--oldest-first":
            oldestFirst = true
        default:
            guard !arg.hasPrefix("-"), database == nil else {
                throw ToolError.message("unexpected argument: \(arg)\n\n\(usage())")
            }
            database = arg
        }
    }
    return Options(
        database: database,
        output: output,
        me: me,
        oldestFirst: oldestFirst
    )
}

private func expandedURL(_ path: String) -> URL {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
}

private func resolveDatabase(_ supplied: String?) throws -> URL {
    if let supplied {
        let url = expandedURL(supplied)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.message("Database not found: \(url.path)")
        }
        return url
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
        home.appendingPathComponent("Library/Messages/chat.db"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("chat.db")
    ]
    if let match = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        return match
    }
    throw ToolError.message(
        "could not auto-detect chat.db. Pass its path explicitly. " +
        "If macOS reports Operation not permitted, grant Full Disk Access to your terminal."
    )
}

private func makeSnapshot(of source: URL, in directory: URL) throws -> URL {
    let destination = directory.appendingPathComponent("chat.db")
    for suffix in ["", "-wal", "-shm"] {
        let sourceFile = URL(fileURLWithPath: source.path + suffix)
        if FileManager.default.fileExists(atPath: sourceFile.path) {
            try FileManager.default.copyItem(
                at: sourceFile,
                to: URL(fileURLWithPath: destination.path + suffix)
            )
        }
    }
    return destination
}

private func dateFromAppleTimestamp(_ value: Double?) -> Date? {
    guard let value, value.isFinite else { return nil }
    let seconds = abs(value) > 1e11 ? value / 1e9 : value
    let result = seconds + appleEpochSeconds
    guard result.isFinite else { return nil }
    return Date(timeIntervalSince1970: result)
}

private func formatDate(_ date: Date?) -> String {
    guard let date else { return "unknown-time" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

private func decodeAttributedBody(_ value: SQLiteValue) -> String? {
    guard case .blob(let blob) = value, !blob.isEmpty,
        let marker = blob.range(of: Data("NSString".utf8))
    else { return nil }

    // Array indices always start at 0, unlike Data slices.
    let bytes = Array(blob[marker.upperBound...])
    var offset = 5  // skip the 5 header bytes after "NSString"
    guard bytes.count > offset else { return nil }

    let first = bytes[offset]
    let length: Int
    if first == 0x81 {
        guard bytes.count >= offset + 3 else { return nil }
        length = Int(UInt16(bytes[offset + 1]) | UInt16(bytes[offset + 2]) << 8)
        offset += 3
    } else if first == 0x82 {
        guard bytes.count >= offset + 5 else { return nil }
        length = Int(
            UInt32(bytes[offset + 1])
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3]) << 16
                | UInt32(bytes[offset + 4]) << 24)
        offset += 5
    } else {
        length = Int(first)
        offset += 1
    }

    guard length >= 0, length <= bytes.count - offset else { return nil }
    return String(decoding: bytes[offset..<offset + length], as: UTF8.self)
}

private func safeFilename(_ value: String, maximumLength: Int = 120) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".+@-"))
    let result = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        .trimmingCharacters(in: CharacterSet(charactersIn: "_."))
    return String((result.isEmpty ? "unknown" : result).prefix(maximumLength))
}

private func messageText(_ row: SQLiteRow, me: String, fallbackSender: String) -> String? {
    let content = row["text"].string ?? decodeAttributedBody(row["attributedBody"]) ?? ""
    let cleaned = content.replacingOccurrences(of: "\u{fffc}", with: "").trimmingCharacters(
        in: .whitespacesAndNewlines)
    let attachments = row["attachments"].string
    var parts: [String] = []
    if !cleaned.isEmpty { parts.append(cleaned) }
    if let attachments, !attachments.isEmpty { parts.append("[attachment: \(attachments)]") }
    guard !parts.isEmpty else { return nil }
    let sender = row["is_from_me"].integer == 1 ? me : (row["sender_id"].string ?? fallbackSender)
    let prefix = "[\(formatDate(dateFromAppleTimestamp(row["date"].number)))] \(sender): "
    let indent = String(repeating: " ", count: prefix.count)
    return prefix
        + parts.joined(separator: "\n").replacingOccurrences(of: "\n", with: "\n" + indent)
}

private func export(
    database: SQLiteDatabase,
    output: URL,
    me: String,
    oldestFirst: Bool
) throws -> (Int, Int) {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let order = oldestFirst ? "ASC" : "DESC"
    let conversations = try database.rows(
        """
        SELECT chat_identifier, MAX(style) AS style, MAX(display_name) AS display_name,
               group_concat(ROWID, ',') AS chat_ids
        FROM chat GROUP BY chat_identifier
        """
    )
    var usedNames = Set<String>()
    var filesWritten = 0
    var totalMessages = 0

    for conversation in conversations {
        guard let identifier = conversation["chat_identifier"].string,
            let idsCSV = conversation["chat_ids"].string
        else { continue }
        let ids = idsCSV.split(separator: ",").compactMap { Int64($0) }
        guard !ids.isEmpty else { continue }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let bindings = ids.map { SQLiteValue.integer($0) }
        let messageRows = try database.rows(
            """
            SELECT m.ROWID, m.date, m.is_from_me, m.text, m.attributedBody,
                   m.service, h.id AS sender_id,
                   (SELECT group_concat(COALESCE(a.transfer_name, a.filename), '; ')
                      FROM message_attachment_join maj
                      JOIN attachment a ON a.ROWID = maj.attachment_id
                     WHERE maj.message_id = m.ROWID) AS attachments
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN (\(placeholders))
              AND COALESCE(m.associated_message_type, 0) = 0
              AND COALESCE(m.item_type, 0) = 0
            ORDER BY m.date \(order), m.ROWID \(order)
            """,
            bindings: bindings
        )

        var seen = Set<Int64>()
        var lines: [String] = []
        for row in messageRows {
            guard let rowID = row["ROWID"].integer, seen.insert(rowID).inserted,
                let line = messageText(row, me: me, fallbackSender: identifier)
            else { continue }
            lines.append(line)
        }
        guard !lines.isEmpty else { continue }

        let participantRows = try database.rows(
            """
            SELECT DISTINCT h.id
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id IN (\(placeholders))
            ORDER BY h.id
            """,
            bindings: bindings
        )
        let participants = participantRows.compactMap { $0["id"].string }
        let displayName =
            conversation["display_name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? identifier
        let isGroup = conversation["style"].integer == 43 || participants.count > 1
        let base = isGroup ? "group_\(safeFilename(displayName))" : safeFilename(identifier)
        var filename = base
        var suffix = 2
        while usedNames.contains(filename.lowercased()) {
            filename = "\(base)_\(suffix)"
            suffix += 1
        }
        usedNames.insert(filename.lowercased())

        let header = [
            "Conversation: \(displayName)",
            "Type:         \(isGroup ? "group" : "one-to-one")",
            "Participants: \(me), "
                + (participants.isEmpty ? identifier : participants.joined(separator: ", ")),
            "Messages:     \(lines.count)",
            "Order:        \(oldestFirst ? "oldest" : "most recent") first",
            String(repeating: "=", count: 72),
            "",
        ]
        let content = (header + [lines.joined(separator: "\n\n")]).joined(separator: "\n") + "\n"
        try content.write(
            to: output.appendingPathComponent(filename + ".txt"), atomically: true, encoding: .utf8)
        filesWritten += 1
        totalMessages += lines.count
    }
    return (filesWritten, totalMessages)
}

@main
private enum MessagesExporter {
    static func main() {
        do {
            let options = try parseArguments()
            let databaseURL = try resolveDatabase(options.database)
            let output = expandedURL(options.output)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
                "messages_export_\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let snapshot: URL
            do {
                snapshot = try makeSnapshot(of: databaseURL, in: temporary)
            } catch {
                throw ToolError.message(
                    "Unable to copy chat.db. Grant Full Disk Access to your terminal and retry. \(error)"
                )
            }
            let database = try SQLiteDatabase(path: snapshot)
            let (files, messages) = try export(
                database: database, output: output, me: options.me, oldestFirst: options.oldestFirst
            )
            print(
                "Wrote \(files) conversation file(s), \(messages) messages -> \(output.standardizedFileURL.path)"
            )
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }
}
