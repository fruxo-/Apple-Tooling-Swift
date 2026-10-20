import CSQLite
import Foundation

private let appleEpoch = Date(timeIntervalSince1970: 978_307_200)
private let sessionTypes = [0: "individual", 1: "group", 2: "broadcast", 3: "status", 4: "community"]
private let messageTypes: [Int: String] = [
    1: "Image", 2: "Video", 3: "Audio", 4: "Contact", 5: "Location",
    6: "System/group event", 7: "Link", 8: "Document", 10: "System message",
    11: "GIF", 14: "Deleted message", 15: "Sticker"
]

private enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    var string: String? {
        if case let .text(value) = self { return value }
        return nil
    }

    var int: Int {
        switch self {
        case let .integer(value): return Int(value)
        case let .real(value): return Int(value)
        default: return 0
        }
    }

    var double: Double? {
        switch self {
        case let .integer(value): return Double(value)
        case let .real(value): return value
        default: return nil
        }
    }
}

private struct SQLiteRow {
    let values: [String: SQLiteValue]
    subscript(_ key: String) -> SQLiteValue { values[key] ?? .null }
    func text(_ key: String) -> String? { self[key].string }
    func int(_ key: String) -> Int { self[key].int }
    func double(_ key: String) -> Double? { self[key].double }
}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: URL) throws {
        let result = sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle { sqlite3_close(handle) }
            self.handle = nil
            throw ToolError.message(reason)
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func rows(_ sql: String, bindings: [String] = []) throws -> [SQLiteRow] {
        guard let handle else { throw ToolError.message("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ToolError.message(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in bindings.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard result == SQLITE_OK else { throw ToolError.message(String(cString: sqlite3_errmsg(handle))) }
        }

        var resultRows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw ToolError.message(String(cString: sqlite3_errmsg(handle))) }

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
                        values[name] = .text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
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

    func tableExists(_ name: String) throws -> Bool {
        try !rows("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", bindings: [name]).isEmpty
    }
}

private enum ToolError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case let .message(value): return value
        }
    }
}

private struct Options {
    var database: String?
    var output = "whatsapp_export"
    var utc = false
    var includeStatus = false
}

private func usage() -> String {
    """
    Usage: whatsapp-exporter [DB] [-o|--output DIR] [--utc] [--include-status]
    Export WhatsApp ChatStorage.sqlite to one text file per chat.
      DB                     database path (auto-detected if omitted)
      -o, --output DIR       output directory (default: ./whatsapp_export)
      --utc                  write timestamps in UTC instead of local time
      --include-status       include status/broadcast pseudo-chats
      -h, --help             show this help
    """
}

private func parseArguments() throws -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "-h", "--help":
            print(usage())
            exit(0)
        case "-o", "--output":
            guard !args.isEmpty else { throw ToolError.message("missing value for \(arg)") }
            options.output = args.removeFirst()
        case "--utc":
            options.utc = true
        case "--include-status":
            options.includeStatus = true
        default:
            guard !arg.hasPrefix("-"), options.database == nil else {
                throw ToolError.message("unexpected argument: \(arg)\n\n\(usage())")
            }
            options.database = arg
        }
    }
    return options
}

private func resolveDatabase(_ supplied: String?) throws -> URL {
    if let supplied {
        let url = URL(fileURLWithPath: NSString(string: supplied).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError.message("file not found: \(url.path)")
        }
        return url
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = [
        home.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/ChatStorage.sqlite"),
        home.appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp/ChatStorage.sqlite"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("ChatStorage.sqlite")
    ]
    if let match = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        return match
    }
    throw ToolError.message(
        "could not auto-detect ChatStorage.sqlite. Pass its path explicitly. " +
        "If macOS reports Operation not permitted, grant Full Disk Access to your terminal."
    )
}

private func makeSnapshot(of source: URL) throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wa_export_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("ChatStorage.sqlite")
    do {
        try FileManager.default.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
            }
        }
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
    return (directory, destination)
}

private func date(_ value: Double?, utc: Bool) -> Date? {
    guard let value, value.isFinite else { return nil }
    let result = appleEpoch.addingTimeInterval(value)
    return result.timeIntervalSince1970.isFinite ? result : nil
}

private func formatDate(_ value: Date?, utc: Bool) -> String {
    guard let value else { return "????-??-?? ??:??:??" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = utc ? TimeZone(secondsFromGMT: 0) : .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: value)
}

private func displayJID(_ jid: String?) -> String {
    guard let jid, !jid.isEmpty else { return "Unknown" }
    let components = jid.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let user = String(components[0])
    let server = components.count == 2 ? String(components[1]) : ""
    if ["s.whatsapp.net", "c.us"].contains(server), user.allSatisfy(\.isNumber) { return "+\(user)" }
    return user.isEmpty ? jid : user
}

private func safeFilename(_ value: String, limit: Int = 80) -> String {
    let invalid = CharacterSet(charactersIn: "\0<>:\"/\\|?*").union(.controlCharacters)
    let cleaned = value.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    return String((cleaned.isEmpty ? "chat" : cleaned).prefix(limit))
}

private func humanSize(_ number: Double?) -> String {
    guard var value = number, value != 0 else { return "" }
    let units = ["B", "KB", "MB", "GB"]
    var index = 0
    while value >= 1024 && index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return index == 0 ? String(format: "%.0f %@", value, units[index]) : String(format: "%.1f %@", value, units[index])
}

private func messageBody(_ row: SQLiteRow) -> String {
    let type = row.int("ZMESSAGETYPE")
    var parts: [String] = []
    if let label = messageTypes[type] {
        var extra: [String] = []
        if type == 2 || type == 3, row.double("ZMOVIEDURATION").map({ $0 != 0 }) == true {
            extra.append("\(row.double("ZMOVIEDURATION")!)s")
        }
        if let size = row.double("ZFILESIZE"), size != 0 { extra.append(humanSize(size)) }
        parts.append("[\(label)\(extra.isEmpty ? "" : ": " + extra.joined(separator: ", "))]")
    } else if type != 0 {
        parts.append("[Type \(type)]")
    }
    if type == 4, let name = row.text("ZVCARDNAME"), !name.isEmpty { parts.append(name) }
    if type == 5, let latitude = row.double("ZLATITUDE"), let longitude = row.double("ZLONGITUDE") {
        parts.append(String(format: "https://maps.google.com/?q=%.6f,%.6f", latitude, longitude))
    }
    let caption = row.text("ZTEXT").flatMap { $0.isEmpty ? nil : $0 } ?? row.text("ZTITLE")
    if let caption, !caption.isEmpty { parts.append(caption) }
    if let path = row.text("ZMEDIALOCALPATH"), !path.isEmpty { parts.append("(file: \(path))" ) }
    if type == 6, caption == nil { parts.append("(event code \(row.int("ZGROUPEVENTTYPE")))" ) }
    return parts.isEmpty ? "[Empty message]" : parts.joined(separator: " ")
}

private func exportChat(
    database: SQLiteDatabase,
    chat: SQLiteRow,
    pushNames: [String: String],
    output: URL,
    utc: Bool,
    usedNames: inout Set<String>
) throws -> Int {
    let sessionType = chat.int("ZSESSIONTYPE")
    let isGroup = sessionType == 1
    let jid = chat.text("ZCONTACTJID") ?? ""
    let title = chat.text("ZPARTNERNAME").flatMap { $0.isEmpty ? nil : $0 } ?? pushNames[jid] ?? displayJID(jid)
    let rows = try database.rows(
        """
        SELECT m.Z_PK, m.ZMESSAGEDATE, m.ZISFROMME, m.ZMESSAGETYPE, m.ZGROUPEVENTTYPE,
               m.ZTEXT, m.ZPUSHNAME, m.ZFROMJID, m.ZSTARRED,
               gm.ZMEMBERJID, gm.ZCONTACTNAME,
               mi.ZMEDIALOCALPATH, mi.ZTITLE, mi.ZVCARDNAME, mi.ZLATITUDE,
               mi.ZLONGITUDE, mi.ZFILESIZE, mi.ZMOVIEDURATION
        FROM ZWAMESSAGE m
        LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM
        LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER
        WHERE m.ZCHATSESSION = ?
        ORDER BY m.ZMESSAGEDATE, m.Z_PK
        """,
        bindings: [String(chat.int("Z_PK"))]
    )

    let base = safeFilename(title)
    let suffix = safeFilename(jid.split(separator: "@", maxSplits: 1).first.map(String.init) ?? String(chat.int("Z_PK")), limit: 40)
    let stem = "\(base) [\(suffix)]"
    var filename = "\(stem).txt"
    var n = 1
    while usedNames.contains(filename.lowercased()) {
        n += 1
        filename = "\(stem) (\(n)).txt"
    }
    usedNames.insert(filename.lowercased())

    let firstDate = rows.first.flatMap { date($0.double("ZMESSAGEDATE"), utc: utc) }
    let lastDate = rows.last.flatMap { date($0.double("ZMESSAGEDATE"), utc: utc) }
    let zone = utc ? "UTC" : (TimeZone.current.abbreviation() ?? "local time")
    var text = """
    Chat:      \(title)
    JID:       \(jid)
    Type:      \(sessionTypes[sessionType] ?? "type \(sessionType)")\(chat.int("ZARCHIVED") != 0 ? " (archived)" : "")
    Messages:  \(rows.count)
    Range:     \(formatDate(firstDate, utc: utc)) -> \(formatDate(lastDate, utc: utc)) (\(zone))
    Exported:  \(formatDate(Date(), utc: false))
    \(String(repeating: "=", count: 72))

    """

    var lastDay: String?
    for row in rows {
        let timestamp = date(row.double("ZMESSAGEDATE"), utc: utc)
        let day = timestamp.map { String(formatDate($0, utc: utc).prefix(10)) }
        if let day, day != lastDay {
            text += "\n--- \(day) ---\n"
            lastDay = day
        }
        let sender: String
        if row.int("ZISFROMME") != 0 {
            sender = "Me"
        } else if isGroup {
            let memberJID = row.text("ZMEMBERJID") ?? ""
            sender = row.text("ZCONTACTNAME").flatMap { $0.isEmpty ? nil : $0 }
                ?? row.text("ZPUSHNAME").flatMap { $0.isEmpty ? nil : $0 }
                ?? pushNames[memberJID] ?? displayJID(memberJID)
        } else {
            sender = chat.text("ZPARTNERNAME").flatMap { $0.isEmpty ? nil : $0 }
                ?? row.text("ZPUSHNAME").flatMap { $0.isEmpty ? nil : $0 }
                ?? pushNames[jid] ?? displayJID(jid)
        }
        let body = messageBody(row).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\n    ")
        let star = row.int("ZSTARRED") != 0 ? " *" : ""
        if [6, 10].contains(row.int("ZMESSAGETYPE")) {
            text += "[\(formatDate(timestamp, utc: utc))] \(body)\(star)\n"
        } else {
            text += "[\(formatDate(timestamp, utc: utc))] \(sender): \(body)\(star)\n"
        }
    }
    try text.write(to: output.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    print(String(format: "%7d msgs  %@", rows.count, filename))
    return rows.count
}

@main
private enum WhatsAppExporter {
    static func main() {
        do {
            let options = try parseArguments()
            let source = try resolveDatabase(options.database)
            let output = URL(fileURLWithPath: NSString(string: options.output).expandingTildeInPath)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            print("Reading:  \(source.path)")
            let (temporaryDirectory, snapshot) = try makeSnapshot(of: source)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let database = try SQLiteDatabase(path: snapshot)

            for table in ["ZWACHATSESSION", "ZWAMESSAGE"] where try !database.tableExists(table) {
                throw ToolError.message("table \(table) not found - is this a WhatsApp ChatStorage.sqlite?")
            }

            var pushNames: [String: String] = [:]
            if try database.tableExists("ZWAPROFILEPUSHNAME") {
                for row in try database.rows("SELECT ZJID, ZPUSHNAME FROM ZWAPROFILEPUSHNAME") {
                    if let jid = row.text("ZJID"), let name = row.text("ZPUSHNAME") { pushNames[jid] = name }
                }
            }
            let chats = try database.rows(
                """
                SELECT s.Z_PK, s.ZCONTACTJID, s.ZPARTNERNAME, s.ZSESSIONTYPE, s.ZARCHIVED
                FROM ZWACHATSESSION s
                WHERE EXISTS (SELECT 1 FROM ZWAMESSAGE m WHERE m.ZCHATSESSION = s.Z_PK)
                ORDER BY s.ZLASTMESSAGEDATE DESC
                """
            )
            var usedNames = Set<String>()
            var exported = 0
            var totalMessages = 0
            for chat in chats {
                if !options.includeStatus,
                   (chat.int("ZSESSIONTYPE") == 3 || chat.text("ZCONTACTJID") == "status@broadcast") {
                    continue
                }
                totalMessages += try exportChat(
                    database: database, chat: chat, pushNames: pushNames,
                    output: output, utc: options.utc, usedNames: &usedNames
                )
                exported += 1
            }
            print("\nDone: \(exported) chats, \(totalMessages) messages -> \(output.standardizedFileURL.path)")
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }
}
