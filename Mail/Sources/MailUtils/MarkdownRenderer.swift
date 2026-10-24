import Foundation

struct MarkdownRenderer {
    let people: PersonFormatter

    /// Summary header (timestamps, counts, participants), then every email in chronological order.
    func renderThread(_ doc: ThreadDocument) -> String {
        let first = doc.first
        let last = doc.last
        let title = TextTools.subject(of: first, parsed: doc.parsed[0])
        let titleBase = TextTools.baseSubject(title)

        var out = "# \(TextTools.oneLine(title))\n\n"
        out += "- **Earliest email:** \(DateFormat.iso(first.date))\n"
        out += "- **Latest email:** \(DateFormat.iso(last.date))\n"
        out += "- **Emails:** \(doc.messages.count)\n"
        out += "- **Participants:** \(doc.participants.count)\n"
        if doc.thread.conversationID > 0 {
            out += "- **Mail conversation id:** \(doc.thread.conversationID)\n"
        }

        out += "\n| Participant | Emails sent |\n|---|---:|\n"
        for participant in doc.participants {
            out += "| \(Self.tableCell(people.display(participant.email))) | \(participant.sent) |\n"
        }

        for (offset, message) in doc.messages.enumerated() {
            let parsedBody = doc.parsed[offset]
            out += "\n---\n\n"
            out += "## \(offset + 1). \(DateFormat.iso(message.date)) — \(people.display(message.senderEmail, name: message.senderName))\n\n"

            // Only show the subject when it changed beyond a Re:/Fwd: prefix.
            let subject = TextTools.subject(of: message, parsed: parsedBody)
            if TextTools.baseSubject(subject) != titleBase {
                out += "- **Subject:** \(TextTools.oneLine(subject))\n"
            }
            out += bullets(message, parsed: parsedBody)
            out += "\n" + bodyBlock(message, parsed: parsedBody)
        }
        return out
    }

    func renderIndex(entries: [IndexEntry], info: IndexInfo) -> String {
        var lines = ["# Mail export", ""]
        lines.append("Generated \(DateFormat.iso(Date())). All times are UTC.")
        if let range = info.rangeDescription {
            lines.append("Range: \(range).")
        }
        lines.append("\(info.threads) threads, \(info.emails) emails.")
        lines.append("")
        lines.append("| Thread | Emails | Participants | First | Last |")
        lines.append("|---|---:|---:|---|---|")
        for entry in entries {
            let name = entry.fileBase + "." + OutputKind.markdown.fileExtension
            let link = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            lines.append(
                "| [\(Self.tableCell(entry.title))](\(link)) | \(entry.emails) | \(entry.participants) | "
                + "\(DateFormat.day(entry.first)) | \(DateFormat.day(entry.last)) |"
            )
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces

    private func bullets(_ message: Message, parsed: ParsedEmail?) -> String {
        var out = ""
        for group in TextTools.recipientGroups(of: message) {
            let list = group.members.map { people.display($0.email, name: $0.name) }.joined(separator: ", ")
            out += "- **\(group.label):** \(list)\n"
        }
        if let parsed, !parsed.attachments.isEmpty {
            out += "- **Attachments:** \(parsed.attachments.map(TextTools.oneLine).joined(separator: ", "))\n"
        }
        if let messageID = message.messageIDHeader ?? parsed?.messageID, !messageID.isEmpty {
            out += "- **Message-ID:** `\(messageID)`\n"
        }
        if let mailbox = message.copies.first?.mailboxURL, !mailbox.isEmpty {
            out += "- **Mailbox:** `\(mailbox)`\n"
        }
        return out
    }

    private func bodyBlock(_ message: Message, parsed: ParsedEmail?) -> String {
        var out = ""
        if let parsed {
            out += parsed.body.isEmpty ? "_(empty body)_\n" : Self.fenced(parsed.body) + "\n"
        } else {
            out += "_Body unavailable: no matching .emlx file was found (the message may not be downloaded)._\n"
            if let snippet = message.snippet, !snippet.isEmpty {
                out += "\n**Snippet:** \(TextTools.oneLine(snippet))\n"
            }
        }
        return out
    }

    /// Fenced code block with a fence longer than any backtick run inside the text.
    private static func fenced(_ text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)text\n\(text)\n\(fence)"
    }

    private static func tableCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }
}
