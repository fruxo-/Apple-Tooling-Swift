import Foundation

/// Output formats a thread can be rendered to.
enum OutputKind {
    case markdown
    case html

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .html: return "html"
        }
    }
}

/// Everything a renderer needs about one thread, prepared once and shared by all formats.
struct ThreadDocument {
    let thread: MailThread
    /// The thread's emails, chronological.
    let messages: [Message]
    /// Parsed .emlx per email (nil when no body file was found), same order as `messages`.
    let parsed: [ParsedEmail?]
    /// Most active senders first.
    let participants: [ThreadParticipant]

    var first: Message { messages[0] }
    var last: Message { messages[messages.count - 1] }

    /// The first email's subject on a single line.
    var title: String {
        TextTools.oneLine(TextTools.subject(of: first, parsed: parsed[0]))
    }
}

struct IndexEntry {
    let title: String
    /// File name without extension.
    let fileBase: String
    let emails: Int
    let participants: Int
    let first: Date
    let last: Date
}

struct IndexInfo {
    let threads: Int
    let emails: Int
    let rangeDescription: String?
}

/// "Alice (alice@example.com)", or just the address when no name is known.
struct PersonFormatter {
    let names: [String: String]

    func display(_ email: String, name: String? = nil) -> String {
        let provided = (name?.isEmpty == false) ? name : nil
        let raw = provided ?? names[email] ?? ""
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        if cleaned.isEmpty || cleaned.lowercased() == email { return email }
        return "\(cleaned) (\(email))"
    }
}

/// Format-independent text helpers.
enum TextTools {
    static func subject(of message: Message, parsed: ParsedEmail?) -> String {
        message.subject.isEmpty ? (parsed?.subject ?? "(no subject)") : message.subject
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static let replyPrefix = try? NSRegularExpression(
        pattern: #"^(\s*(re|fwd?|aw|sv|wg)\s*:\s*)+"#,
        options: [.caseInsensitive]
    )

    /// Subject without leading Re:/Fwd:-style prefixes, lowercased, for comparing within a thread.
    static func baseSubject(_ subject: String) -> String {
        let collapsed = oneLine(subject)
        guard let regex = replyPrefix else { return collapsed.lowercased() }
        let range = NSRange(location: 0, length: (collapsed as NSString).length)
        return regex.stringByReplacingMatches(in: collapsed, range: range, withTemplate: "")
            .lowercased()
    }

    static func slug(_ text: String, limit: Int = 60) -> String {
        var output = ""
        var lastWasDash = true
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                output.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                output.append("-")
                lastWasDash = true
            }
        }
        output = String(output.prefix(limit))
        while output.hasSuffix("-") { output.removeLast() }
        return output.isEmpty ? "no-subject" : output
    }

    /// Folder for an export: the searched-for address(es), or "all" when no --party was given.
    /// Several addresses are joined with "__". `--only` exports get an "__only" suffix so they never
    /// mix with a full export of the same party.
    static func folderName(forParties parties: [String], only: Bool = false) -> String {
        guard !parties.isEmpty else { return "all" }
        var forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        forbidden.formUnion(.controlCharacters)
        var cleaned = parties.joined(separator: "__").components(separatedBy: forbidden).joined(
            separator: "_")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = String(cleaned.prefix(120))
        if cleaned.isEmpty { return "all" }
        return only ? cleaned + "__only" : cleaned
    }

    /// Recipients grouped by role, empty groups omitted.
    static func recipientGroups(of message: Message) -> [(label: String, members: [Recipient])] {
        let groups: [(label: String, members: [Recipient])] = [
            ("To", message.recipients.filter { $0.type == 0 }),
            ("Cc", message.recipients.filter { $0.type == 1 }),
            ("Bcc", message.recipients.filter { $0.type == 2 }),
            ("Other recipients", message.recipients.filter { $0.type < 0 || $0.type > 2 }),
        ]
        return groups.filter { !$0.members.isEmpty }
    }
}
