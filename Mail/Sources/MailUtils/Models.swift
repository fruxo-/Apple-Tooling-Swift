import Foundation

// MARK: - Errors & logging

enum ExportError: LocalizedError {
    case mailNotFound(String)
    case database(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .mailNotFound(let text), .database(let text), .io(let text):
            return text
        }
    }
}

enum Log {
    static func info(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

// MARK: - Mail location

struct MailLocation {
    let root: URL

    var databaseURL: URL {
        root.appendingPathComponent("MailData/Envelope Index")
    }

    /// `override` may be a version folder (e.g. ~/Library/Mail/V10) or its parent (~/Library/Mail).
    static func resolve(override: String?) throws -> MailLocation {
        let fileManager = FileManager.default
        let base: URL
        if let override {
            base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail", isDirectory: true)
        }

        func hasDatabase(_ directory: URL) -> Bool {
            fileManager.fileExists(atPath: directory.appendingPathComponent("MailData/Envelope Index").path)
        }

        if hasDatabase(base) {
            return MailLocation(root: base)
        }

        let children = (try? fileManager.contentsOfDirectory(atPath: base.path)) ?? []
        let versions: [(number: Int, name: String)] = children.compactMap { name in
            guard name.hasPrefix("V"), let number = Int(name.dropFirst()) else { return nil }
            return (number, name)
        }
        .sorted { $0.number > $1.number }

        for version in versions {
            let candidate = base.appendingPathComponent(version.name, isDirectory: true)
            if hasDatabase(candidate) {
                return MailLocation(root: candidate)
            }
        }

        throw ExportError.mailNotFound("""
            Could not find Mail's "MailData/Envelope Index" under \(base.path).
            If that is the default location, your terminal probably lacks Full Disk Access \
            (System Settings > Privacy & Security > Full Disk Access). \
            Otherwise point --mail-directory at the right folder.
            """)
    }
}

// MARK: - Message model

struct MessageCopy {
    let rowID: Int64
    let remoteID: Int64?
    let mailboxURL: String
}

struct Recipient {
    let email: String
    let name: String
    /// Believed to be 0 = To, 1 = Cc, 2 = Bcc. Verify with `SELECT DISTINCT type FROM recipients`.
    let type: Int64
}

struct Message {
    /// The same message can live in several mailboxes; copies share a `global_message_id`.
    var copies: [MessageCopy]
    let globalID: Int64
    /// Mail's `conversation_id`; 0 means the message was not assigned to a conversation.
    let conversationID: Int64
    let timestamp: Int64
    let senderEmail: String
    let senderName: String
    let subject: String
    let snippet: String?
    let messageIDHeader: String?
    var recipients: [Recipient] = []

    var primaryRowID: Int64 { copies[0].rowID }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

// MARK: - Date formatting (always UTC)

enum DateFormat {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func makeFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter
    }

    private static let dayFormatter = makeFormatter("yyyy-MM-dd")
    private static let fileStampFormatter = makeFormatter("yyyy-MM-dd_HHmmss")

    /// 2024-03-02T09:15:00Z
    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
    /// 2024-03-02
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
    /// 2024-03-02_091500 (sorts chronologically, safe in file names)
    static func fileStamp(_ date: Date) -> String { fileStampFormatter.string(from: date) }
}

// MARK: - Threads

/// One Mail conversation (`conversation_id`), restricted to the emails that were selected.
struct MailThread {
    /// 0 for an email Mail did not assign to any conversation; it forms a thread of its own.
    let conversationID: Int64
    /// Indexes into the messages array, in chronological order.
    let messageIndexes: [Int]

    var count: Int { messageIndexes.count }
}

struct ThreadParticipant {
    let email: String
    /// Emails this participant sent within the thread (0 for people who only received).
    let sent: Int
}

extension MailThread {
    /// Groups `messages` (which must already be chronological) into threads, ordered by first email.
    ///
    /// - Parameter parties: if not empty, only threads in which *every* one of these addresses took part
    ///   (as sender, To, Cc or Bcc of any email) are kept.
    /// - Parameter minMessages: threads with fewer emails are dropped.
    static func build(from messages: [Message], parties: Set<String>, minMessages: Int) -> [MailThread] {
        var order: [Int64] = []
        var buckets: [Int64: [Int]] = [:]

        for (index, message) in messages.enumerated() {
            let key = message.conversationID > 0 ? message.conversationID : -message.primaryRowID
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(index)
        }

        var threads: [MailThread] = []
        for key in order {
            let thread = MailThread(conversationID: max(key, 0), messageIndexes: buckets[key] ?? [])
            if thread.count < minMessages { continue }
            if !parties.isEmpty {
                let present = Set(thread.participants(in: messages).map { $0.email })
                if !parties.isSubset(of: present) { continue }
            }
            threads.append(thread)
        }
        return threads
    }

    /// Everyone who sent or received an email in the thread, most active senders first.
    func participants(in messages: [Message]) -> [ThreadParticipant] {
        var sent: [String: Int] = [:]
        var seen: [String] = []

        func note(_ email: String) {
            if sent[email] == nil {
                sent[email] = 0
                seen.append(email)
            }
        }

        for index in messageIndexes {
            let message = messages[index]
            note(message.senderEmail)
            sent[message.senderEmail, default: 0] += 1
            for recipient in message.recipients {
                note(recipient.email)
            }
        }

        return seen
            .map { ThreadParticipant(email: $0, sent: sent[$0] ?? 0) }
            .sorted { $0.sent != $1.sent ? $0.sent > $1.sent : $0.email < $1.email }
    }
}

// MARK: - Display names

enum DisplayNames {
    /// First non-empty display name seen for each address.
    static func collect(from messages: [Message]) -> [String: String] {
        var names: [String: String] = [:]

        func note(_ email: String, _ raw: String) {
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            if !name.isEmpty, names[email] == nil, name.lowercased() != email {
                names[email] = name
            }
        }

        for message in messages {
            note(message.senderEmail, message.senderName)
            for recipient in message.recipients {
                note(recipient.email, recipient.name)
            }
        }
        return names
    }
}
