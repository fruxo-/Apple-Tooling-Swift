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

// MARK: - Correspondences (pairs of parties)

struct PairKey: Hashable, Comparable {
    let first: String
    let second: String

    init(_ a: String, _ b: String) {
        if a <= b {
            first = a
            second = b
        } else {
            first = b
            second = a
        }
    }

    static func < (lhs: PairKey, rhs: PairKey) -> Bool {
        (lhs.first, lhs.second) < (rhs.first, rhs.second)
    }
}

struct Correspondence {
    let key: PairKey
    /// Indexes into the messages array, in chronological order.
    let messageIndexes: [Int]

    /// `messages` must already be sorted chronologically (MailStore does this).
    static func build(from messages: [Message], parties: Set<String>, minMessages: Int) -> [Correspondence] {
        var buckets: [PairKey: [Int]] = [:]

        for (index, message) in messages.enumerated() {
            let sender = message.senderEmail
            var others = Set<String>()
            for recipient in message.recipients where recipient.email != sender {
                others.insert(recipient.email)
            }
            for other in others {
                let key = PairKey(sender, other)
                if accepts(key, parties: parties) {
                    buckets[key, default: []].append(index)
                }
            }
        }

        return buckets
            .filter { $0.value.count >= minMessages }
            .map { Correspondence(key: $0.key, messageIndexes: $0.value) }
            .sorted { $0.key < $1.key }
    }

    private static func accepts(_ key: PairKey, parties: Set<String>) -> Bool {
        switch parties.count {
        case 0:
            return true
        case 1:
            return parties.contains(key.first) || parties.contains(key.second)
        default:
            return parties.contains(key.first) && parties.contains(key.second)
        }
    }

    /// First non-empty display name seen for each address.
    static func collectNames(from messages: [Message]) -> [String: String] {
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
