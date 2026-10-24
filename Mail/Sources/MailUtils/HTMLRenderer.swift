import Foundation

/// Self-contained HTML pages: inline CSS, no scripts, no remote resources.
/// Email bodies are always shown as escaped plain text, never as the sender's HTML.
struct HTMLRenderer {
    let people: PersonFormatter

    // MARK: - Thread page

    func renderThread(_ doc: ThreadDocument) -> String {
        let first = doc.first
        let last = doc.last
        let title = TextTools.subject(of: first, parsed: doc.parsed[0])
        let titleBase = TextTools.baseSubject(title)
        let heading = TextTools.oneLine(title)

        var body = "<header>\n<h1>\(Self.escape(heading))</h1>\n<dl class=\"meta\">\n"
        body += Self.metaRow("Earliest email", Self.timeTag(first.date))
        body += Self.metaRow("Latest email", Self.timeTag(last.date))
        body += Self.metaRow("Emails", "\(doc.messages.count)")
        body += Self.metaRow("Participants", "\(doc.participants.count)")
        if doc.thread.conversationID > 0 {
            body += Self.metaRow("Mail conversation id", "\(doc.thread.conversationID)")
        }
        body += "</dl>\n"

        body += "<table class=\"participants\">\n"
        body += "<thead><tr><th>Participant</th><th class=\"num\">Emails sent</th></tr></thead>\n<tbody>\n"
        for participant in doc.participants {
            body += "<tr><td>\(Self.escape(people.display(participant.email)))</td>"
            body += "<td class=\"num\">\(participant.sent)</td></tr>\n"
        }
        body += "</tbody>\n</table>\n</header>\n"

        for (offset, message) in doc.messages.enumerated() {
            let parsedBody = doc.parsed[offset]
            body += "<article class=\"email\" id=\"email-\(offset + 1)\">\n"
            body += "<h2>\(offset + 1). \(Self.timeTag(message.date)) — "
            body += "\(Self.escape(people.display(message.senderEmail, name: message.senderName)))</h2>\n"
            body += emailMeta(message, parsed: parsedBody, titleBase: titleBase)
            body += bodyHTML(message, parsed: parsedBody)
            body += "</article>\n"
        }

        return Self.page(title: heading, body: body)
    }

    private func emailMeta(_ message: Message, parsed: ParsedEmail?, titleBase: String) -> String {
        var rows = ""

        // Only show the subject when it changed beyond a Re:/Fwd: prefix.
        let subject = TextTools.subject(of: message, parsed: parsed)
        if TextTools.baseSubject(subject) != titleBase {
            rows += Self.metaRow("Subject", Self.escape(TextTools.oneLine(subject)))
        }
        for group in TextTools.recipientGroups(of: message) {
            let list = group.members.map { people.display($0.email, name: $0.name) }.joined(separator: ", ")
            rows += Self.metaRow(group.label, Self.escape(list))
        }
        if let parsed, !parsed.attachments.isEmpty {
            let list = parsed.attachments.map(TextTools.oneLine).joined(separator: ", ")
            rows += Self.metaRow("Attachments", Self.escape(list))
        }
        if let messageID = message.messageIDHeader ?? parsed?.messageID, !messageID.isEmpty {
            rows += Self.metaRow("Message-ID", "<code>\(Self.escape(messageID))</code>")
        }
        if let mailbox = message.copies.first?.mailboxURL, !mailbox.isEmpty {
            rows += Self.metaRow("Mailbox", "<code>\(Self.escape(mailbox))</code>")
        }
        return rows.isEmpty ? "" : "<dl class=\"meta\">\n\(rows)</dl>\n"
    }

    private func bodyHTML(_ message: Message, parsed: ParsedEmail?) -> String {
        guard let parsed else {
            var out = "<p class=\"missing\">Body unavailable: no matching .emlx file was found "
            out += "(the message may not be downloaded).</p>\n"
            if let snippet = message.snippet, !snippet.isEmpty {
                out += "<p class=\"snippet\"><strong>Snippet:</strong> \(Self.escape(TextTools.oneLine(snippet)))</p>\n"
            }
            return out
        }
        if parsed.body.isEmpty {
            return "<p class=\"missing\">(empty body)</p>\n"
        }
        return "<div class=\"body\">\n\(Self.bodyBlocks(parsed.body))</div>\n"
    }

    // MARK: - Body text and quoted replies

    struct BodySegment {
        let quoted: Bool
        var lines: [String]
    }

    /// Splits a plain-text body into runs of quoted lines (starting with ">") and everything else.
    /// A blank line between two quoted lines belongs to the quote.
    static func segments(of text: String) -> [BodySegment] {
        let lines = text.components(separatedBy: "\n")
        func isBlank(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).isEmpty
        }

        var quoted = lines.map { line in
            line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(">")
        }

        var i = 0
        while i < lines.count {
            if !quoted[i] && isBlank(lines[i]) {
                var j = i
                while j < lines.count && !quoted[j] && isBlank(lines[j]) { j += 1 }
                if i > 0 && quoted[i - 1] && j < lines.count && quoted[j] {
                    for k in i..<j { quoted[k] = true }
                }
                i = j
            } else {
                i += 1
            }
        }

        var result: [BodySegment] = []
        for (index, line) in lines.enumerated() {
            if let lastIndex = result.indices.last, result[lastIndex].quoted == quoted[index] {
                result[lastIndex].lines.append(line)
            } else {
                result.append(BodySegment(quoted: quoted[index], lines: [line]))
            }
        }
        return result
    }

    /// Plain text as `<pre>` blocks; quoted runs of 3+ lines are folded into `<details>`
    /// (unless the whole email is quoted, in which case nothing is hidden).
    static func bodyBlocks(_ text: String) -> String {
        let parts = segments(of: text)
        let hasOwnText = parts.contains { segment in
            !segment.quoted && !segment.lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        var out = ""
        for segment in parts {
            let joined = segment.lines.joined(separator: "\n")
            if segment.quoted {
                let count = segment.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                let block = "<pre class=\"quoted\">\(escape(joined))</pre>\n"
                if count >= 3 && hasOwnText {
                    out += "<details class=\"quote\"><summary>Show quoted text (\(count) lines)</summary>\n"
                    out += block
                    out += "</details>\n"
                } else {
                    out += block
                }
            } else {
                let trimmed = joined.trimmingCharacters(in: .newlines)
                if !trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
                    out += "<pre>\(escape(trimmed))</pre>\n"
                }
            }
        }
        return out
    }

    // MARK: - Index page

    func renderIndex(entries: [IndexEntry], info: IndexInfo) -> String {
        var body = "<header>\n<h1>Mail export</h1>\n<dl class=\"meta\">\n"
        body += Self.metaRow("Generated", Self.timeTag(Date()))
        if let range = info.rangeDescription {
            body += Self.metaRow("Range", Self.escape(range))
        }
        body += Self.metaRow("Threads", "\(info.threads)")
        body += Self.metaRow("Emails", "\(info.emails)")
        body += "</dl>\n</header>\n"

        body += "<table class=\"index\">\n"
        body += "<thead><tr><th>Thread</th><th class=\"num\">Emails</th><th class=\"num\">Participants</th>"
        body += "<th>First</th><th>Last</th></tr></thead>\n<tbody>\n"
        for entry in entries {
            let name = entry.fileBase + "." + OutputKind.html.fileExtension
            let link = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            body += "<tr><td><a href=\"\(Self.escape(link))\">\(Self.escape(entry.title))</a></td>"
            body += "<td class=\"num\">\(entry.emails)</td><td class=\"num\">\(entry.participants)</td>"
            body += "<td>\(DateFormat.day(entry.first))</td><td>\(DateFormat.day(entry.last))</td></tr>\n"
        }
        body += "</tbody>\n</table>\n"

        return Self.page(title: "Mail export", body: body)
    }

    // MARK: - Helpers

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func metaRow(_ label: String, _ valueHTML: String) -> String {
        "<dt>\(label)</dt><dd>\(valueHTML)</dd>\n"
    }

    private static func timeTag(_ date: Date) -> String {
        let iso = DateFormat.iso(date)
        return "<time datetime=\"\(iso)\">\(iso)</time>"
    }

    private static func page(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        <main>
        \(body)</main>
        </body>
        </html>
        """
    }

    private static let css = """
    :root { color-scheme: light dark; --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --soft: #f5f5f7; --accent: #0a60d8; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #1c1c1e; --fg: #f2f2f7; --muted: #98989d; --line: #3a3a3c; --soft: #2c2c2e; --accent: #6cb2ff; }
    }
    body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
    main { max-width: 52rem; margin: 0 auto; padding: 2rem 1.25rem 4rem; }
    a { color: var(--accent); }
    h1 { font-size: 1.6rem; line-height: 1.25; margin: 0 0 1rem; }
    h2 { font-size: 1.05rem; margin: 0 0 .5rem; }
    dl.meta { display: grid; grid-template-columns: max-content 1fr; gap: .2rem 1rem; margin: 0 0 1rem; font-size: .9rem; }
    dl.meta dt { color: var(--muted); }
    dl.meta dd { margin: 0; overflow-wrap: anywhere; }
    code { font-size: .85em; }
    table { border-collapse: collapse; font-size: .9rem; margin: 0 0 1.5rem; }
    th, td { text-align: left; padding: .3rem .8rem .3rem 0; border-bottom: 1px solid var(--line); vertical-align: top; }
    th.num, td.num { text-align: right; padding-left: .8rem; }
    th:last-child, td:last-child { padding-right: 0; }
    article.email { border-top: 1px solid var(--line); margin-top: 1.5rem; padding-top: 1.25rem; }
    .body pre { margin: 0 0 .75rem; font: inherit; white-space: pre-wrap; overflow-wrap: anywhere; }
    .body pre.quoted { color: var(--muted); border-left: 3px solid var(--line); padding-left: .75rem; }
    details.quote { margin: 0 0 .75rem; }
    details.quote summary { cursor: pointer; color: var(--muted); font-size: .85rem; }
    .missing, .snippet { color: var(--muted); }
    @media print {
      main { max-width: none; padding: 0; }
      a { color: inherit; }
    }
    """
}
