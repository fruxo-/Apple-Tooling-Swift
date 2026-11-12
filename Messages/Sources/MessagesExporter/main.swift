import CSQLite
import Foundation
import NaturalLanguage

private let appleEpochSeconds = 978_307_200.0

private func makeTimestampFormatter(utc: Bool) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = utc ? (TimeZone(secondsFromGMT: 0) ?? .current) : .current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}

private let localTimestampFormatter = makeTimestampFormatter(utc: false)
private let utcTimestampFormatter = makeTimestampFormatter(utc: true)

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

        // Read column metadata once per statement, not once per cell.
        let columnCount = sqlite3_column_count(statement)
        let columnNames = (0..<columnCount).map {
            String(cString: sqlite3_column_name(statement, $0))
        }

        var resultRows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw ToolError.message(String(cString: sqlite3_errmsg(handle)))
            }
            var values: [String: SQLiteValue] = [:]
            for index in 0..<columnCount {
                let name = columnNames[Int(index)]
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

    func tableExists(_ name: String) throws -> Bool {
        try !rows(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            bindings: [.text(name)]
        ).isEmpty
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
    var utc = false
    var includeStatus = false      // accepted for CLI parity with whatsapp-exporter; has no effect here
    var stats = false
    var party: String?
    var topics = false
    var language: String?
    var topicCount = 15
    var ignore: Set<String> = []
}

private func usage() -> String {
    """
    Usage: messages-exporter [DB] [-o|--output DIR] [--me NAME] [--oldest-first] [--utc]
                             [--include-status] [--party NAME] [--stats]
                             [--topics [N]] [--lang CODE] [--ignore WORD,WORD,...]
    Export Messages chat.db to one text file per chat,
    or print message statistics (--stats) / the main topics (--topics) instead.
      DB                     database path (auto-detected if omitted)
      -o, --output DIR       output directory (default: ./messages_export); --out is an alias
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

private func fold(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        .trimmingCharacters(in: .whitespacesAndNewlines)
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
            .appendingPathComponent("chat.db"),
    ]
    if let match = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        return match
    }
    throw ToolError.message(
        "could not auto-detect chat.db. Pass its path explicitly. "
            + "If macOS reports Operation not permitted, grant Full Disk Access to your terminal."
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

private func formatDate(_ date: Date?, utc: Bool) -> String {
    guard let date else { return "unknown-time" }
    return (utc ? utcTimestampFormatter : localTimestampFormatter).string(from: date)
}

// MARK: - Conversations and messages

/// One conversation = every `chat` row sharing a chat_identifier (e.g. the iMessage and SMS
/// threads with the same number are merged), exactly as the original exporter did.
private struct Conversation {
    let identifier: String
    let title: String          // group name when set, otherwise the identifier (number / e-mail)
    let isGroup: Bool
    let chatIDs: [Int64]
    let participants: [String] // handle ids (numbers / e-mails), sorted
}

private func loadConversations(_ database: SQLiteDatabase) throws -> [Conversation] {
    var participantsByChat: [Int64: [String]] = [:]
    let participantRows = try database.rows(
        """
        SELECT chj.chat_id AS chat_id, h.id AS handle
        FROM chat_handle_join chj
        JOIN handle h ON h.ROWID = chj.handle_id
        """
    )
    for row in participantRows {
        if let chatID = row["chat_id"].integer, let handle = row["handle"].string {
            participantsByChat[chatID, default: []].append(handle)
        }
    }

    // Only conversations that have messages, most recently active first.
    let rows = try database.rows(
        """
        SELECT c.chat_identifier AS chat_identifier, MAX(c.style) AS style,
               MAX(c.display_name) AS display_name, group_concat(c.ROWID, ',') AS chat_ids,
               MAX((SELECT MAX(m.date)
                      FROM chat_message_join cmj
                      JOIN message m ON m.ROWID = cmj.message_id
                     WHERE cmj.chat_id = c.ROWID)) AS last_date
        FROM chat c
        GROUP BY c.chat_identifier
        HAVING last_date IS NOT NULL
        ORDER BY last_date DESC
        """
    )

    var result: [Conversation] = []
    for row in rows {
        guard let identifier = row["chat_identifier"].string,
            let idsCSV = row["chat_ids"].string
        else { continue }
        let ids = idsCSV.split(separator: ",").compactMap { Int64($0) }
        guard !ids.isEmpty else { continue }
        var participants = Set<String>()
        for id in ids { for handle in participantsByChat[id] ?? [] { participants.insert(handle) } }
        let sortedParticipants = participants.sorted()
        let name = row["display_name"].string.flatMap { $0.isEmpty ? nil : $0 }
        result.append(
            Conversation(
                identifier: identifier,
                title: name ?? identifier,
                isGroup: row["style"].integer == 43 || sortedParticipants.count > 1,
                chatIDs: ids,
                participants: sortedParticipants
            ))
    }
    return result
}

private struct ChatMessage {
    let date: Date?
    let sender: String       // already resolved: the --me label, the handle id, or the chat identifier
    let text: String         // cleaned body text, may be empty for attachment-only messages
    let attachments: String  // "; "-joined attachment names, empty when none
}

/// Messages of a conversation in chronological order. Tapbacks/reactions and group events are
/// left out, as are messages with neither text nor attachments (same rules as the export).
private func fetchMessages(
    database: SQLiteDatabase, conversation: Conversation, me: String
) throws -> [ChatMessage] {
    let placeholders = Array(repeating: "?", count: conversation.chatIDs.count).joined(separator: ",")
    let rows = try database.rows(
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
        ORDER BY m.date ASC, m.ROWID ASC
        """,
        bindings: conversation.chatIDs.map { SQLiteValue.integer($0) }
    )

    var seen = Set<Int64>()
    var messages: [ChatMessage] = []
    messages.reserveCapacity(rows.count)
    for row in rows {
        guard let rowID = row["ROWID"].integer, seen.insert(rowID).inserted else { continue }
        let content = row["text"].string ?? decodeAttributedBody(row["attributedBody"]) ?? ""
        let text = content.replacingOccurrences(of: "\u{fffc}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = row["attachments"].string ?? ""
        if text.isEmpty && attachments.isEmpty { continue }
        let sender = row["is_from_me"].integer == 1 ? me : (row["sender_id"].string ?? conversation.identifier)
        messages.append(
            ChatMessage(
                date: dateFromAppleTimestamp(row["date"].number),
                sender: sender, text: text, attachments: attachments))
    }
    return messages
}

private func exportLine(_ message: ChatMessage, utc: Bool) -> String {
    var parts: [String] = []
    if !message.text.isEmpty { parts.append(message.text) }
    if !message.attachments.isEmpty { parts.append("[attachment: \(message.attachments)]") }
    let prefix = "[\(formatDate(message.date, utc: utc))] \(message.sender): "
    let indent = String(repeating: " ", count: prefix.count)
    return prefix + parts.joined(separator: "\n").replacingOccurrences(of: "\n", with: "\n" + indent)
}

private func exportConversations(
    database: SQLiteDatabase,
    conversations: [Conversation],
    output: URL,
    options: Options
) throws -> (Int, Int) {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var usedNames = Set<String>()
    var filesWritten = 0
    var totalMessages = 0

    for conversation in conversations {
        var messages = try fetchMessages(database: database, conversation: conversation, me: options.me)
        guard !messages.isEmpty else { continue }
        // The query is chronological; newest-first (the default) just reverses it.
        if !options.oldestFirst { messages.reverse() }
        let lines = messages.map { exportLine($0, utc: options.utc) }

        let base =
            conversation.isGroup
            ? "group_\(safeFilename(conversation.title))" : safeFilename(conversation.identifier)
        var filename = base
        var suffix = 2
        while usedNames.contains(filename.lowercased()) {
            filename = "\(base)_\(suffix)"
            suffix += 1
        }
        usedNames.insert(filename.lowercased())

        let header = [
            "Conversation: \(conversation.title)",
            "Type:         \(conversation.isGroup ? "group" : "one-to-one")",
            "Participants: \(options.me), "
                + (conversation.participants.isEmpty
                    ? conversation.identifier : conversation.participants.joined(separator: ", ")),
            "Messages:     \(lines.count)",
            "Order:        \(options.oldestFirst ? "oldest" : "most recent") first",
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

// MARK: - --party (conversation selection)

/// Picks exactly one conversation for `--party`. Matches the title (group name), the identifier
/// (number / e-mail / chat id) or, digits only, the phone number ("+39 333 123 4567" works).
/// An exact match wins; otherwise a partial match is accepted if it is unambiguous (partial
/// matching also looks at the participants of group chats).
private func selectConversation(_ conversations: [Conversation], party: String) throws -> Conversation {
    let needle = fold(party)
    guard !needle.isEmpty else { throw ToolError.message("--party needs a non-empty value") }
    let phoneCharacters = " +-()."
    let digits = String(party.filter(\.isNumber))
    let looksLikePhone = !digits.isEmpty && party.allSatisfy { $0.isNumber || phoneCharacters.contains($0) }

    // Digits of a value that is a phone number (so e-mails and "chat123..." ids are not treated as one).
    func phoneDigits(_ value: String) -> String? {
        guard value.allSatisfy({ $0.isNumber || phoneCharacters.contains($0) }) else { return nil }
        let result = String(value.filter(\.isNumber))
        return result.isEmpty ? nil : result
    }
    func isExact(_ conversation: Conversation) -> Bool {
        if fold(conversation.title) == needle || fold(conversation.identifier) == needle { return true }
        return looksLikePhone && phoneDigits(conversation.identifier) == digits
    }
    func isPartial(_ conversation: Conversation) -> Bool {
        if fold(conversation.title).contains(needle) || fold(conversation.identifier).contains(needle) {
            return true
        }
        for participant in conversation.participants where fold(participant).contains(needle) { return true }
        guard looksLikePhone else { return false }
        if let value = phoneDigits(conversation.identifier), value.contains(digits) { return true }
        for participant in conversation.participants {
            if let value = phoneDigits(participant), value.contains(digits) { return true }
        }
        return false
    }

    var matches = conversations.filter(isExact)
    if matches.isEmpty { matches = conversations.filter(isPartial) }

    if matches.count == 1 { return matches[0] }
    if matches.isEmpty {
        throw ToolError.message("no chat matches '\(party)'. Run without --party to see every chat.")
    }
    var message = "'\(party)' matches \(matches.count) chats:\n"
    for conversation in matches.prefix(10) {
        message += "  - \(conversation.title)  [\(conversation.identifier)]\n"
    }
    if matches.count > 10 { message += "  ... and \(matches.count - 10) more\n" }
    message += "Use a longer name, the phone number, the e-mail address or the full chat identifier to pick one."
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

private func computeStats(messages: [ChatMessage], utc: Bool) -> ChatStats {
    // ISO 8601 calendar: weeks run Monday-Sunday and week 1 is the one containing the first Thursday.
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = utc ? (TimeZone(secondsFromGMT: 0) ?? .current) : .current

    var stats = ChatStats()
    for message in messages {
        guard let timestamp = message.date else {
            stats.undated += 1
            continue
        }
        let sender = message.sender

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
        if stats.first == nil { stats.first = timestamp }   // messages are in chronological order
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

private func statsReport(conversation: Conversation, stats: ChatStats, utc: Bool) -> String {
    let senders = stats.totals.sorted(by: byCountThenName).map { $0.key }
    let zone = utc ? "UTC" : (TimeZone.current.abbreviation() ?? "local time")

    var lines: [String] = [
        "Chat:      \(conversation.title)",
        "ID:        \(conversation.identifier)",
        "Type:      \(conversation.isGroup ? "group" : "one-to-one")",
        "Messages:  \(stats.counted) from \(senders.count) sender\(senders.count == 1 ? "" : "s") (tapbacks and system events excluded)",
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
    conversation: Conversation,
    options: Options
) throws -> String {
    // Text messages only: attachment-only messages, link-only messages, tapbacks and group events
    // carry no usable text.
    let all = try fetchMessages(database: database, conversation: conversation, me: options.me)

    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = options.utc ? (TimeZone(secondsFromGMT: 0) ?? .current) : .current

    var prepared: [(sender: String, text: String, day: String)] = []
    for message in all {
        guard let timestamp = message.date else { continue }
        let text = cleanText(message.text)
        if !text.isEmpty {
            prepared.append((sender: message.sender, text: text, day: dayLabel(timestamp, calendar: calendar)))
        }
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
            sender: item.sender,
            day: item.day, text: text, nouns: nouns
        ))
    }

    return topicsReport(
        conversation: conversation, messages: messages,
        language: language, languageSource: languageSource,
        limit: options.topicCount, utc: options.utc
    )
}

private func topicsReport(
    conversation: Conversation,
    messages: [TopicMessage],
    language: NLLanguage,
    languageSource: String,
    limit: Int,
    utc: Bool
) -> String {
    let languageName = Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue) ?? language.rawValue
    let zone = utc ? "UTC" : (TimeZone.current.abbreviation() ?? "local time")
    var lines: [String] = [
        "Chat:      \(conversation.title)",
        "ID:        \(conversation.identifier)",
        "Topics:    NaturalLanguage noun extraction, on-device | language: \(languageName) (\(languageSource))",
        "Messages:  \(messages.count) text messages analysed (attachments, link-only messages, tapbacks and system events skipped)",
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
private enum MessagesExporter {
    static func main() {
        do {
            let options = try parseArguments()
            let databaseURL = try resolveDatabase(options.database)
            let output = expandedURL(options.output)
            let reading = "Reading:  \(databaseURL.path)"
            if options.stats || options.topics {
                // Keep stdout clean so the report can be piped or redirected.
                fputs(reading + "\n", stderr)
            } else {
                print(reading)
            }
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

            for table in ["chat", "message"] {
                if try !database.tableExists(table) {
                    throw ToolError.message("table \(table) not found - is this a Messages chat.db?")
                }
            }

            var conversations = try loadConversations(database)
            if let party = options.party {
                conversations = [try selectConversation(conversations, party: party)]
            }

            if options.stats || options.topics {
                for (index, conversation) in conversations.enumerated() {
                    if index > 0 { print("\n") }
                    if options.stats {
                        let messages = try fetchMessages(database: database, conversation: conversation, me: options.me)
                        let stats = computeStats(messages: messages, utc: options.utc)
                        print(statsReport(conversation: conversation, stats: stats, utc: options.utc))
                    }
                    if options.topics {
                        if options.stats { print("\n") }
                        print(try extractTopics(database: database, conversation: conversation, options: options))
                    }
                }
                return
            }

            let (files, messages) = try exportConversations(
                database: database, conversations: conversations, output: output, options: options
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
