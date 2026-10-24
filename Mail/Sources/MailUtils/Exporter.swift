import Foundation

struct ExportSummary {
    var threads = 0
    var emails = 0
    var filesWritten = 0
    var missingBodies = 0
}

struct Exporter {
    let outputDirectory: URL
    let locator: EmlxLocator
    let names: [String: String]
    let formats: [OutputKind]
    let verbose: Bool

    /// Writes one file per thread and format into a single flat folder, plus an index per format.
    func export(_ threads: [MailThread],
                messages: [Message],
                rangeDescription: String?) throws -> ExportSummary {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let people = PersonFormatter(names: names)
        let markdown = MarkdownRenderer(people: people)
        let html = HTMLRenderer(people: people)

        var summary = ExportSummary()
        var entries: [IndexEntry] = []

        for (position, thread) in threads.enumerated() {
            let threadMessages = thread.messageIndexes.map { messages[$0] }

            var parsedBodies: [ParsedEmail?] = []
            for message in threadMessages {
                var parsed: ParsedEmail?
                if let emlx = locator.locate(message) {
                    parsed = try? EmlxReader.parse(url: emlx)
                }
                if parsed == nil {
                    summary.missingBodies += 1
                    if verbose {
                        Log.info("  no body for message \(message.primaryRowID): \(TextTools.oneLine(message.subject))")
                    }
                }
                parsedBodies.append(parsed)
            }

            let document = ThreadDocument(
                thread: thread,
                messages: threadMessages,
                parsed: parsedBodies,
                participants: thread.participants(in: messages)
            )
            let base = Self.fileBase(for: thread, first: document.first)

            for kind in formats {
                let text: String
                switch kind {
                case .markdown: text = markdown.renderThread(document)
                case .html: text = html.renderThread(document)
                }
                let file = outputDirectory.appendingPathComponent(base + "." + kind.fileExtension)
                try text.write(to: file, atomically: true, encoding: .utf8)
                try? fileManager.setAttributes(
                    [.creationDate: document.first.date, .modificationDate: document.last.date],
                    ofItemAtPath: file.path
                )
                summary.filesWritten += 1
            }

            summary.threads += 1
            summary.emails += threadMessages.count

            if verbose || (position + 1) % 50 == 0 || position + 1 == threads.count {
                print("[\(position + 1)/\(threads.count)] \(base)")
            }

            entries.append(IndexEntry(
                title: document.title,
                fileBase: base,
                emails: threadMessages.count,
                participants: document.participants.count,
                first: document.first.date,
                last: document.last.date
            ))
        }

        let info = IndexInfo(threads: summary.threads, emails: summary.emails, rangeDescription: rangeDescription)
        for kind in formats {
            let text: String
            switch kind {
            case .markdown: text = markdown.renderIndex(entries: entries, info: info)
            case .html: text = html.renderIndex(entries: entries, info: info)
            }
            try text.write(
                to: outputDirectory.appendingPathComponent("index." + kind.fileExtension),
                atomically: true,
                encoding: .utf8
            )
        }
        return summary
    }

    /// `<first email's UTC timestamp>_<subject slug>_<thread id>`, without extension.
    private static func fileBase(for thread: MailThread, first: Message) -> String {
        let id = thread.conversationID > 0 ? "thread\(thread.conversationID)" : "msg\(first.primaryRowID)"
        return "\(DateFormat.fileStamp(first.date))_\(TextTools.slug(first.subject))_\(id)"
    }
}
