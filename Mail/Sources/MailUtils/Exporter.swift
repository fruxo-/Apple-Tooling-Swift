import Foundation

struct ExportSummary {
    var correspondences = 0
    var filesWritten = 0
    var missingBodies = 0
}

struct Exporter {
    let outputDirectory: URL
    let locator: EmlxLocator
    let names: [String: String]
    let verbose: Bool

    // Everything is UTC so file names sort chronologically regardless of local time zone.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Export

    func export(_ correspondences: [Correspondence],
                messages: [Message],
                rangeDescription: String?) throws -> ExportSummary {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var summary = ExportSummary()
        var indexRows: [String] = []

        for (position, correspondence) in correspondences.enumerated() {
            let folderName = Self.sanitized("\(correspondence.key.first)__\(correspondence.key.second)")
            let folder = outputDirectory.appendingPathComponent(folderName, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

            for messageIndex in correspondence.messageIndexes {
                let message = messages[messageIndex]

                var parsed: ParsedEmail?
                if let emlx = locator.locate(message) {
                    parsed = try? EmlxReader.parse(url: emlx)
                }
                if parsed == nil {
                    summary.missingBodies += 1
                    if verbose {
                        Log.info("  no body for message \(message.primaryRowID): \(Self.oneLine(message.subject))")
                    }
                }

                let file = folder.appendingPathComponent(fileName(for: message))
                try render(message, parsed: parsed).write(to: file, atomically: true, encoding: .utf8)
                try? fileManager.setAttributes(
                    [.modificationDate: message.date, .creationDate: message.date],
                    ofItemAtPath: file.path
                )
                summary.filesWritten += 1
            }

            summary.correspondences += 1
            print("[\(position + 1)/\(correspondences.count)] \(folderName): \(correspondence.messageIndexes.count) messages")

            let first = messages[correspondence.messageIndexes.first!].date
            let last = messages[correspondence.messageIndexes.last!].date
            let title = "\(display(correspondence.key.first, name: nil)) ↔ \(display(correspondence.key.second, name: nil))"
            let link = folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folderName
            indexRows.append(
                "| [\(Self.tableCell(title))](\(link)/) | \(correspondence.messageIndexes.count) | "
                + "\(Self.dayFormatter.string(from: first)) | \(Self.dayFormatter.string(from: last)) |"
            )
        }

        try writeIndex(rows: indexRows, rangeDescription: rangeDescription)
        return summary
    }

    private func writeIndex(rows: [String], rangeDescription: String?) throws {
        var lines = ["# Mail export", ""]
        lines.append("Generated \(Self.isoFormatter.string(from: Date())). All times are UTC.")
        if let rangeDescription {
            lines.append("Range: \(rangeDescription).")
        }
        lines.append("")
        lines.append("| Correspondence | Messages | First | Last |")
        lines.append("|---|---:|---|---|")
        lines.append(contentsOf: rows)
        lines.append("")

        try lines.joined(separator: "\n").write(
            to: outputDirectory.appendingPathComponent("index.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Rendering one message

    private func render(_ message: Message, parsed: ParsedEmail?) -> String {
        let subject = message.subject.isEmpty ? (parsed?.subject ?? "(no subject)") : message.subject

        var out = "# \(Self.oneLine(subject))\n\n"
        out += "- **Date:** \(Self.isoFormatter.string(from: message.date))\n"
        out += "- **From:** \(display(message.senderEmail, name: message.senderName))\n"

        let groups: [(label: String, members: [Recipient])] = [
            ("To", message.recipients.filter { $0.type == 0 }),
            ("Cc", message.recipients.filter { $0.type == 1 }),
            ("Bcc", message.recipients.filter { $0.type == 2 }),
            ("Other recipients", message.recipients.filter { $0.type < 0 || $0.type > 2 }),
        ]
        for group in groups where !group.members.isEmpty {
            let people = group.members.map { display($0.email, name: $0.name) }.joined(separator: ", ")
            out += "- **\(group.label):** \(people)\n"
        }

        if let parsed, !parsed.attachments.isEmpty {
            out += "- **Attachments:** \(parsed.attachments.map(Self.oneLine).joined(separator: ", "))\n"
        }
        if let messageID = message.messageIDHeader ?? parsed?.messageID, !messageID.isEmpty {
            out += "- **Message-ID:** `\(messageID)`\n"
        }
        if let mailbox = message.copies.first?.mailboxURL, !mailbox.isEmpty {
            out += "- **Mailbox:** `\(mailbox)`\n"
        }

        out += "\n---\n\n"

        if let parsed {
            out += parsed.body.isEmpty ? "_(empty body)_\n" : Self.fenced(parsed.body) + "\n"
        } else {
            out += "_Body unavailable: no matching .emlx file was found (the message may not be downloaded)._\n"
            if let snippet = message.snippet, !snippet.isEmpty {
                out += "\n**Snippet:** \(Self.oneLine(snippet))\n"
            }
        }
        return out
    }

    private func display(_ email: String, name: String?) -> String {
        let provided = (name?.isEmpty == false) ? name : nil
        let raw = provided ?? names[email] ?? ""
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
        if cleaned.isEmpty || cleaned.lowercased() == email { return email }
        return "\(cleaned) (\(email))"
    }

    private func fileName(for message: Message) -> String {
        let stamp = Self.fileStampFormatter.string(from: message.date)
        return "\(stamp)_\(Self.slug(message.subject))_\(message.primaryRowID).md"
    }

    // MARK: - String helpers

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

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func tableCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func sanitized(_ text: String) -> String {
        var forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        forbidden.formUnion(.controlCharacters)
        var cleaned = text.components(separatedBy: forbidden).joined(separator: "_")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return String(cleaned.prefix(120))
    }

    private static func slug(_ text: String, limit: Int = 60) -> String {
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
}
