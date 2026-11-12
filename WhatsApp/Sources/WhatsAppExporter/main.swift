import CSQLite
import Foundation
import NaturalLanguage

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
    var me = "Me"
    var oldestFirst = false
    var utc = false
    var includeStatus = false
    var stats = false
    var party: String?
    var topics = false
    var language: String?
    var topicCount = 15
    var ignore: Set<String> = []
}

private func usage() -> String {
    """
    Usage: whatsapp-exporter [DB] [-o|--output DIR] [--me NAME] [--oldest-first] [--utc]
                             [--include-status] [--party NAME] [--stats]
                             [--topics [N]] [--lang CODE] [--ignore WORD,WORD,...]
    Export WhatsApp ChatStorage.sqlite to one text file per chat,
    or print message statistics (--stats) / the main topics (--topics) instead.
      DB                     database path (auto-detected if omitted)
      -o, --output DIR       output directory (default: ./whatsapp_export); --out is an alias
                             (ignored with --stats and --topics)
      --me NAME              label for your own messages (default: Me)
      --oldest-first         export messages oldest to newest (default: newest first)
      --utc                  use UTC instead of local time (timestamps, day/week/month boundaries)
      --include-status       include WhatsApp status/broadcast pseudo-chats
                             (accepted and ignored by messages-exporter)
      --party NAME           only process one chat. NAME is matched case- and accent-
                             insensitively against the chat name, phone number, e-mail
                             address or chat ID; an exact match wins, otherwise a partial
                             match is accepted if it is unambiguous. Works with and
                             without --stats.
      --stats                print the number of messages per sender per day, per ISO
                             week (Mon-Sun) and per month, instead of exporting files.
                             Covers every chat unless --party is given.
      --topics [N]           list the N (default 15) most-discussed topics of one chat, with
                             who talks about them and when. Topics are the most-mentioned
                             nouns, found on-device with Apple's NaturalLanguage framework.
                             Needs --party.
      --lang CODE            language of the chat, e.g. it, en (default: auto-detect)
      --ignore W1,W2,...     nouns to skip as topics (generic words like "thing", "time")
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
        case "-o", "--output", "--out":
            guard !args.isEmpty else { throw ToolError.message("missing value for \(arg)") }
            options.output = args.removeFirst()
        case "--me":
            guard !args.isEmpty else { throw ToolError.message("missing value for \(arg)") }
            options.me = args.removeFirst()
        case "--oldest-first":
            options.oldestFirst = true
        case "--utc":
            options.utc = true
        case "--include-status":
            options.includeStatus = true
        case "--stats":
            options.stats = true
        case "--topics":
            options.topics = true
            if let next = args.first, let count = Int(next), count > 0 {
                options.topicCount = count
                args.removeFirst()
            }
        case "--lang":
            guard !args.isEmpty else { throw ToolError.message("missing value for \(arg)") }
            options.language = args.removeFirst()
        case "--ignore":
            guard !args.isEmpty else { throw ToolError.message("missing value for \(arg)") }
            for word in args.removeFirst().split(separator: ",") { options.ignore.insert(fold(String(word))) }
        case "--party":
            guard !args.isEmpty else { throw ToolError.message("missing value for \(arg)") }
            options.party = args.removeFirst()
        default:
            guard !arg.hasPrefix("-"), options.database == nil else {
                throw ToolError.message("unexpected argument: \(arg)\n\n\(usage())")
            }
            options.database = arg
        }
    }
    if options.topics && options.party == nil {
        throw ToolError.message("--topics works on a single chat: add --party NAME")
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

private func chatTitle(_ chat: SQLiteRow, pushNames: [String: String]) -> String {
    let jid = chat.text("ZCONTACTJID") ?? ""
    return chat.text("ZPARTNERNAME").flatMap { $0.isEmpty ? nil : $0 } ?? pushNames[jid] ?? displayJID(jid)
}

/// Display name of whoever sent `row`. Expects the row to carry ZISFROMME, ZPUSHNAME,
/// ZMEMBERJID and ZCONTACTNAME (the last two come from the ZWAGROUPMEMBER join).
private func senderName(row: SQLiteRow, chat: SQLiteRow, pushNames: [String: String], me: String) -> String {
    if row.int("ZISFROMME") != 0 { return me }
    if chat.int("ZSESSIONTYPE") == 1 {
        let memberJID = row.text("ZMEMBERJID") ?? ""
        return row.text("ZCONTACTNAME").flatMap { $0.isEmpty ? nil : $0 }
            ?? row.text("ZPUSHNAME").flatMap { $0.isEmpty ? nil : $0 }
            ?? pushNames[memberJID] ?? displayJID(memberJID)
    }
    let jid = chat.text("ZCONTACTJID") ?? ""
    return chat.text("ZPARTNERNAME").flatMap { $0.isEmpty ? nil : $0 }
        ?? row.text("ZPUSHNAME").flatMap { $0.isEmpty ? nil : $0 }
        ?? pushNames[jid] ?? displayJID(jid)
}

private func exportChat(
    database: SQLiteDatabase,
    chat: SQLiteRow,
    pushNames: [String: String],
    output: URL,
    utc: Bool,
    me: String,
    oldestFirst: Bool,
    usedNames: inout Set<String>
) throws -> Int {
    let sessionType = chat.int("ZSESSIONTYPE")
    let jid = chat.text("ZCONTACTJID") ?? ""
    let title = chatTitle(chat, pushNames: pushNames)
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
    Order:     \(oldestFirst ? "oldest" : "newest") first
    Exported:  \(formatDate(Date(), utc: false))
    \(String(repeating: "=", count: 72))

    """

    // The query is chronological; newest-first (the default) just reverses it.
    let ordered = oldestFirst ? rows : Array(rows.reversed())
    var lastDay: String?
    for row in ordered {
        let timestamp = date(row.double("ZMESSAGEDATE"), utc: utc)
        let day = timestamp.map { String(formatDate($0, utc: utc).prefix(10)) }
        if let day, day != lastDay {
            text += "\n--- \(day) ---\n"
            lastDay = day
        }
        let sender = senderName(row: row, chat: chat, pushNames: pushNames, me: me)
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

// MARK: - --party (chat selection)

private func fold(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Picks exactly one chat for `--party`. Matches the chat name, the phone number
/// (digits only, so "+34 600 11 22 33" works) or the JID. An exact match wins over a
/// partial one; if several chats still match, the user is asked to be more specific.
private func selectChat(_ chats: [SQLiteRow], party: String, pushNames: [String: String]) throws -> SQLiteRow {
    let needle = fold(party)
    guard !needle.isEmpty else { throw ToolError.message("--party needs a non-empty value") }
    let digits = String(party.filter(\.isNumber))
    let looksLikePhone = !digits.isEmpty && party.allSatisfy { $0.isNumber || " +-().".contains($0) }

    func isExact(_ chat: SQLiteRow) -> Bool {
        let jid = chat.text("ZCONTACTJID") ?? ""
        let user = jid.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if fold(chatTitle(chat, pushNames: pushNames)) == needle || fold(jid) == needle || fold(user) == needle { return true }
        return looksLikePhone && user == digits
    }
    func isPartial(_ chat: SQLiteRow) -> Bool {
        let jid = chat.text("ZCONTACTJID") ?? ""
        if fold(chatTitle(chat, pushNames: pushNames)).contains(needle) || fold(jid).contains(needle) { return true }
        let user = jid.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return looksLikePhone && user.contains(digits)
    }

    var matches = chats.filter(isExact)
    if matches.isEmpty { matches = chats.filter(isPartial) }

    if matches.count == 1 { return matches[0] }
    if matches.isEmpty {
        throw ToolError.message("no chat matches '\(party)'. Run without --party to see every chat.")
    }
    var message = "'\(party)' matches \(matches.count) chats:\n"
    for chat in matches.prefix(10) {
        message += "  - \(chatTitle(chat, pushNames: pushNames))  [\(chat.text("ZCONTACTJID") ?? "?")]\n"
    }
    if matches.count > 10 { message += "  ... and \(matches.count - 10) more\n" }
    message += "Use a longer name, the phone number, or the full JID to pick one."
    throw ToolError.message(message)
}

// MARK: - --stats

private struct ChatStats {
    typealias Buckets = [String: [String: Int]]   // period label -> sender -> messages
    var daily: Buckets = [:]
    var weekly: Buckets = [:]
    var monthly: Buckets = [:]
    var totals: [String: Int] = [:]
    var counted = 0
    var undated = 0
    var first: Date?
    var last: Date?
}

private func dayLabel(_ date: Date, calendar: Calendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

private func computeStats(
    database: SQLiteDatabase,
    chat: SQLiteRow,
    pushNames: [String: String],
    me: String,
    utc: Bool
) throws -> ChatStats {
    let rows = try database.rows(
        """
        SELECT m.ZMESSAGEDATE, m.ZISFROMME, m.ZMESSAGETYPE, m.ZPUSHNAME,
               gm.ZMEMBERJID, gm.ZCONTACTNAME
        FROM ZWAMESSAGE m
        LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER
        WHERE m.ZCHATSESSION = ?
        ORDER BY m.ZMESSAGEDATE, m.Z_PK
        """,
        bindings: [String(chat.int("Z_PK"))]
    )

    // ISO 8601 calendar: weeks run Monday-Sunday and week 1 is the one containing the first Thursday.
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = utc ? (TimeZone(secondsFromGMT: 0) ?? .current) : .current

    var stats = ChatStats()
    for row in rows {
        // System events (group changes, encryption notices...) have no sender: not counted.
        if [6, 10].contains(row.int("ZMESSAGETYPE")) { continue }
        guard let timestamp = date(row.double("ZMESSAGEDATE"), utc: utc) else {
            stats.undated += 1
            continue
        }
        let sender = senderName(row: row, chat: chat, pushNames: pushNames, me: me)

        let day = dayLabel(timestamp, calendar: calendar)
        let month = String(day.prefix(7))
        let week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: timestamp)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: timestamp)?.start ?? timestamp
        let weekLabel = String(
            format: "%04d-W%02d (%@)",
            week.yearForWeekOfYear ?? 0, week.weekOfYear ?? 0, dayLabel(weekStart, calendar: calendar)
        )

        stats.daily[day, default: [:]][sender, default: 0] += 1
        stats.weekly[weekLabel, default: [:]][sender, default: 0] += 1
        stats.monthly[month, default: [:]][sender, default: 0] += 1
        stats.totals[sender, default: 0] += 1
        stats.counted += 1
        if stats.first == nil { stats.first = timestamp }   // rows are ordered by date
        stats.last = timestamp
    }
    return stats
}

private let matrixSenderLimit = 6

private func padLeft(_ value: String, _ width: Int) -> String {
    String(repeating: " ", count: max(0, width - value.count)) + value
}

private func padRight(_ value: String, _ width: Int) -> String {
    value + String(repeating: " ", count: max(0, width - value.count))
}

private func clip(_ value: String, _ limit: Int) -> String {
    value.count <= limit ? value : String(value.prefix(limit - 1)) + "…"
}

private func byCountThenName(_ a: (key: String, value: Int), _ b: (key: String, value: Int)) -> Bool {
    a.value != b.value ? a.value > b.value : a.key < b.key
}

/// One section of the report. With few senders: a matrix (one row per period, one column per
/// sender). With many senders (big groups) a matrix gets too wide, so each period becomes a
/// small block listing its senders instead.
private func renderSection(
    title: String, periodHeader: String, data: ChatStats.Buckets, senders: [String]
) -> [String] {
    var lines = ["", title, String(repeating: "-", count: title.count)]
    let periods = data.keys.sorted()

    if senders.count <= matrixSenderLimit {
        func cell(_ count: Int) -> String { count == 0 ? "-" : String(count) }
        let names = senders.map { clip($0, 18) }

        var labelWidth = periodHeader.count
        for period in periods { labelWidth = max(labelWidth, period.count) }
        var widths: [Int] = []
        for (index, sender) in senders.enumerated() {
            var width = names[index].count
            for period in periods { width = max(width, cell(data[period]?[sender] ?? 0).count) }
            widths.append(width)
        }
        var totalWidth = "Total".count
        for period in periods { totalWidth = max(totalWidth, String((data[period] ?? [:]).values.reduce(0, +)).count) }

        var header = padRight(periodHeader, labelWidth)
        for (index, name) in names.enumerated() { header += "  " + padLeft(name, widths[index]) }
        header += "  " + padLeft("Total", totalWidth)
        lines.append(header)

        for period in periods {
            let counts = data[period] ?? [:]
            var line = padRight(period, labelWidth)
            for (index, sender) in senders.enumerated() {
                line += "  " + padLeft(cell(counts[sender] ?? 0), widths[index])
            }
            line += "  " + padLeft(String(counts.values.reduce(0, +)), totalWidth)
            lines.append(line)
        }
    } else {
        var nameWidth = 0
        for sender in senders { nameWidth = max(nameWidth, min(sender.count, 30)) }
        for period in periods {
            let counts = data[period] ?? [:]
            lines.append("\(period)  (total \(counts.values.reduce(0, +)))")
            for (sender, count) in counts.sorted(by: byCountThenName) {
                let name = padRight(clip(sender, 30), nameWidth)
                lines.append("    \(name)  \(padLeft(String(count), 5))")
            }
        }
    }
    return lines
}

private func statsReport(chat: SQLiteRow, pushNames: [String: String], stats: ChatStats, utc: Bool) -> String {
    let sessionType = chat.int("ZSESSIONTYPE")
    let senders = stats.totals.sorted(by: byCountThenName).map { $0.key }
    let zone = utc ? "UTC" : (TimeZone.current.abbreviation() ?? "local time")

    var lines: [String] = [
        "Chat:      \(chatTitle(chat, pushNames: pushNames))",
        "JID:       \(chat.text("ZCONTACTJID") ?? "")",
        "Type:      \(sessionTypes[sessionType] ?? "type \(sessionType)")\(chat.int("ZARCHIVED") != 0 ? " (archived)" : "")",
        "Messages:  \(stats.counted) from \(senders.count) sender\(senders.count == 1 ? "" : "s") (system events excluded)",
        "Range:     \(formatDate(stats.first, utc: utc)) -> \(formatDate(stats.last, utc: utc)) (\(zone))"
    ]
    if stats.undated > 0 { lines.append("Note:      \(stats.undated) message(s) without a valid date were skipped") }
    lines.append(String(repeating: "=", count: 72))

    guard stats.counted > 0 else {
        lines.append("No messages with a sender in this chat.")
        return lines.joined(separator: "\n")
    }

    lines.append("")
    lines.append("Total per sender")
    lines.append(String(repeating: "-", count: "Total per sender".count))
    var nameWidth = 0
    for sender in senders { nameWidth = max(nameWidth, min(sender.count, 30)) }
    for sender in senders {
        let count = stats.totals[sender] ?? 0
        let share = String(format: "%.1f%%", Double(count) * 100 / Double(stats.counted))
        let name = padRight(clip(sender, 30), nameWidth)
        lines.append("\(name)  \(padLeft(String(count), 7))  \(padLeft(share, 6))")
    }

    lines += renderSection(title: "Messages per day", periodHeader: "Date", data: stats.daily, senders: senders)
    lines += renderSection(title: "Messages per week (ISO, Mon-Sun)", periodHeader: "Week", data: stats.weekly, senders: senders)
    lines += renderSection(title: "Messages per month", periodHeader: "Month", data: stats.monthly, senders: senders)
    return lines.joined(separator: "\n")
}

// MARK: - --topics (Apple NaturalLanguage noun extraction, fully on-device)

private enum TopicSettings {
    static let minTopicMessages = 5        // a noun must occur in at least this many messages to be a topic
    static let maxPartiesShown = 5         // per topic; in big groups the rest are summarised
    static let languageSampleBytes = 100_000
    static let exampleLength = 110
}

private struct TopicMessage {
    let sender: String
    let day: String           // yyyy-MM-dd in local time (or UTC with --utc)
    let text: String
    let nouns: Set<String>    // distinct nouns (base forms) found in the message
}

/// Collapses newlines and drops URLs so each message is one clean paragraph.
private func cleanText(_ raw: String) -> String {
    raw.components(separatedBy: .newlines)
        .joined(separator: " ")
        .split(separator: " ")
        .filter { !$0.hasPrefix("http") && !$0.hasPrefix("www.") }
        .joined(separator: " ")
}

private func percent(_ share: Double) -> String { String(format: "%.0f%%", share * 100) }

private func resolveLanguage(requested: String?, texts: [String]) throws -> (language: NLLanguage, source: String) {
    if let requested {
        return (NLLanguage(rawValue: requested.lowercased()), "set with --lang")
    }
    var sample = ""
    var bytes = 0
    for text in texts {
        sample += text + "\n"
        bytes += text.utf8.count + 1
        if bytes >= TopicSettings.languageSampleBytes { break }
    }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(sample)
    guard let language = recognizer.dominantLanguage else {
        throw ToolError.message("could not detect the chat language; pass it explicitly, e.g. --lang it")
    }
    return (language, "auto-detected")
}

private func extractTopics(
    database: SQLiteDatabase,
    chat: SQLiteRow,
    pushNames: [String: String],
    options: Options
) throws -> String {
    // Plain text messages only (type 0): media, links, stickers and system events carry no usable text.
    let rows = try database.rows(
        """
        SELECT m.ZMESSAGEDATE, m.ZISFROMME, m.ZMESSAGETYPE, m.ZPUSHNAME, m.ZTEXT,
               gm.ZMEMBERJID, gm.ZCONTACTNAME
        FROM ZWAMESSAGE m
        LEFT JOIN ZWAGROUPMEMBER gm ON gm.Z_PK = m.ZGROUPMEMBER
        WHERE m.ZCHATSESSION = ? AND m.ZMESSAGETYPE = 0 AND m.ZTEXT IS NOT NULL AND m.ZTEXT != ''
        ORDER BY m.ZMESSAGEDATE, m.Z_PK
        """,
        bindings: [String(chat.int("Z_PK"))]
    )

    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = options.utc ? (TimeZone(secondsFromGMT: 0) ?? .current) : .current

    var prepared: [(row: SQLiteRow, text: String, day: String)] = []
    for row in rows {
        guard let timestamp = date(row.double("ZMESSAGEDATE"), utc: options.utc),
              let raw = row.text("ZTEXT") else { continue }
        let text = cleanText(raw)
        if !text.isEmpty { prepared.append((row: row, text: text, day: dayLabel(timestamp, calendar: calendar))) }
    }
    guard !prepared.isEmpty else { throw ToolError.message("no analysable text messages in this chat") }

    let (language, languageSource) = try resolveLanguage(requested: options.language, texts: prepared.map { $0.text })

    // Which NaturalLanguage models exist for this language on this macOS?
    let wordSchemes = NLTagger.availableTagSchemes(for: .word, language: language)
    let canTagNouns = wordSchemes.contains(.lexicalClass)
    let canLemmatize = wordSchemes.contains(.lemma)
    if !canTagNouns {
        fputs("warning: no part-of-speech model for '\(language.rawValue)'; falling back to all longer words as topics (low quality)\n", stderr)
    }
    let minimumLength = canTagNouns ? 3 : 5

    let wordTagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
    var messages: [TopicMessage] = []
    messages.reserveCapacity(prepared.count)

    for item in prepared {
        let text = item.text
        let range = text.startIndex..<text.endIndex

        var nouns = Set<String>()
        wordTagger.string = text
        wordTagger.setLanguage(language, range: range)
        wordTagger.enumerateTags(
            in: range, unit: .word, scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace, .omitOther]
        ) { tag, tokenRange in
            if canTagNouns && tag != .noun { return true }
            var key = String(text[tokenRange])
            if canLemmatize,
               let lemma = wordTagger.tag(at: tokenRange.lowerBound, unit: .word, scheme: .lemma).0?.rawValue,
               !lemma.isEmpty {
                key = lemma
            }
            key = key.lowercased()
            if key.count >= minimumLength,
               !key.contains(where: \.isNumber),
               !options.ignore.contains(fold(key)) {
                nouns.insert(key)
            }
            return true
        }

        messages.append(TopicMessage(
            sender: senderName(row: item.row, chat: chat, pushNames: pushNames, me: options.me),
            day: item.day, text: text, nouns: nouns
        ))
    }

    return topicsReport(
        chat: chat, pushNames: pushNames, messages: messages,
        language: language, languageSource: languageSource,
        limit: options.topicCount, utc: options.utc
    )
}

private func topicsReport(
    chat: SQLiteRow,
    pushNames: [String: String],
    messages: [TopicMessage],
    language: NLLanguage,
    languageSource: String,
    limit: Int,
    utc: Bool
) -> String {
    let languageName = Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue) ?? language.rawValue
    let zone = utc ? "UTC" : (TimeZone.current.abbreviation() ?? "local time")
    var lines: [String] = [
        "Chat:      \(chatTitle(chat, pushNames: pushNames))",
        "JID:       \(chat.text("ZCONTACTJID") ?? "")",
        "Topics:    NaturalLanguage noun extraction, on-device | language: \(languageName) (\(languageSource))",
        "Messages:  \(messages.count) text messages analysed (media, link-only and system messages skipped)",
        "Range:     \(messages.first?.day ?? "?") -> \(messages.last?.day ?? "?") (\(zone))",
        String(repeating: "=", count: 72)
    ]

    // noun -> positions in `messages` (already in chronological order)
    var mentions: [String: [Int]] = [:]
    for (index, message) in messages.enumerated() {
        for noun in message.nouns { mentions[noun, default: []].append(index) }
    }
    let ranked = mentions
        .filter { $0.value.count >= TopicSettings.minTopicMessages }
        .sorted { left, right in
            left.value.count != right.value.count ? left.value.count > right.value.count : left.key < right.key
        }
        .prefix(limit)

    guard !ranked.isEmpty else {
        lines.append("No noun appears in at least \(TopicSettings.minTopicMessages) messages; nothing to report.")
        return lines.joined(separator: "\n")
    }

    lines.append("Top \(ranked.count) topics: nouns found in the most messages (a message counts once per topic)")

    for (rank, entry) in ranked.enumerated() {
        let indices = entry.value
        var perSender: [String: Int] = [:]
        var perMonth: [String: Int] = [:]
        for index in indices {
            perSender[messages[index].sender, default: 0] += 1
            perMonth[String(messages[index].day.prefix(7)), default: 0] += 1
        }
        let firstDay = indices.first.map { messages[$0].day } ?? "?"
        let lastDay = indices.last.map { messages[$0].day } ?? "?"
        let peak = perMonth.sorted(by: byCountThenName).first
        let peakText = peak.map { "peak \($0.key) (\($0.value))" } ?? ""

        lines.append("")
        lines.append("\(padLeft(String(rank + 1), 2)). \(entry.key)  -  \(indices.count) messages  |  \(firstDay) -> \(lastDay)  |  \(peakText)")

        let senders = perSender.sorted(by: byCountThenName)
        var parts: [String] = []
        for (sender, count) in senders.prefix(TopicSettings.maxPartiesShown) {
            parts.append("\(clip(sender, 18)) \(count) (\(percent(Double(count) / Double(indices.count))))")
        }
        if senders.count > TopicSettings.maxPartiesShown {
            parts.append("+\(senders.count - TopicSettings.maxPartiesShown) more")
        }
        lines.append("      \(parts.joined(separator: ", "))")

        // One example so the topic can be sanity-checked: the longest message mentioning it.
        if let example = indices.map({ messages[$0] }).max(by: { $0.text.count < $1.text.count }) {
            lines.append("      e.g. [\(example.day)] \(clip(example.sender, 18)): \"\(clip(example.text, TopicSettings.exampleLength))\"")
        }
    }

    lines.append("")
    lines.append("Topics are single nouns (base forms) found by NaturalLanguage's part-of-speech tagger.")
    lines.append("Hide generic words with --ignore word1,word2 ; change the list length with --topics N.")
    return lines.joined(separator: "\n")
}

@main
private enum WhatsAppExporter {
    static func main() {
        do {
            let options = try parseArguments()
            let source = try resolveDatabase(options.database)
            let output = URL(fileURLWithPath: NSString(string: options.output).expandingTildeInPath)
            if options.stats || options.topics {
                // Keep stdout clean so the report can be piped or redirected.
                fputs("Reading:  \(source.path)\n", stderr)
            } else {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                print("Reading:  \(source.path)")
            }
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
            var chats = try database.rows(
                """
                SELECT s.Z_PK, s.ZCONTACTJID, s.ZPARTNERNAME, s.ZSESSIONTYPE, s.ZARCHIVED
                FROM ZWACHATSESSION s
                WHERE EXISTS (SELECT 1 FROM ZWAMESSAGE m WHERE m.ZCHATSESSION = s.Z_PK)
                ORDER BY s.ZLASTMESSAGEDATE DESC
                """
            )
            if !options.includeStatus {
                chats.removeAll { $0.int("ZSESSIONTYPE") == 3 || $0.text("ZCONTACTJID") == "status@broadcast" }
            }
            if let party = options.party {
                chats = [try selectChat(chats, party: party, pushNames: pushNames)]
            }

            if options.stats || options.topics {
                for (index, chat) in chats.enumerated() {
                    if index > 0 { print("\n") }
                    if options.stats {
                        let stats = try computeStats(database: database, chat: chat, pushNames: pushNames, me: options.me, utc: options.utc)
                        print(statsReport(chat: chat, pushNames: pushNames, stats: stats, utc: options.utc))
                    }
                    if options.topics {
                        if options.stats { print("\n") }
                        print(try extractTopics(database: database, chat: chat, pushNames: pushNames, options: options))
                    }
                }
                return
            }

            var usedNames = Set<String>()
            var exported = 0
            var totalMessages = 0
            for chat in chats {
                totalMessages += try exportChat(
                    database: database, chat: chat, pushNames: pushNames,
                    output: output, utc: options.utc, me: options.me,
                    oldestFirst: options.oldestFirst, usedNames: &usedNames
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
