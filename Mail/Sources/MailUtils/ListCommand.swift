import ArgumentParser
import Foundation

enum OutputFormat: String, ExpressibleByArgument, CaseIterable {
    case table, tsv, json
}

enum SortKey: String, ExpressibleByArgument, CaseIterable {
    /// Most emails first.
    case count
    /// Oldest first email first.
    case first
    /// Most recent latest email first.
    case last
    /// Alphabetical by subject.
    case subject
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the threads found in Mail without exporting anything.",
        discussion: """
        Accepts the same selection options as `export` (date window, --party, --min-messages, …), \
        so it shows exactly the threads `export` would write.
        """
    )

    @OptionGroup var selection: SelectionOptions

    @Option(help: "Output format.")
    var format: OutputFormat = .table

    @Option(help: "Sort order: first (oldest first email first), last (most recent latest email first), count (most emails first) or subject.")
    var sort: SortKey = .first

    func run() throws {
        let loaded = try selection.load()
        let names = DisplayNames.collect(from: loaded.messages)
        let all = loaded.messages

        var rows: [ListRow] = loaded.threads.map { thread in
            let first = all[thread.messageIndexes[0]]
            let last = all[thread.messageIndexes[thread.messageIndexes.count - 1]]
            let participants = thread.participants(in: all).map {
                ListParticipant(address: $0.email, name: names[$0.email], sent: $0.sent)
            }
            return ListRow(
                conversationId: thread.conversationID > 0 ? thread.conversationID : nil,
                subject: first.subject.isEmpty ? "(no subject)" : first.subject,
                emails: thread.count,
                first: DateFormat.iso(first.date),
                last: DateFormat.iso(last.date),
                participants: participants
            )
        }

        // ISO 8601 UTC strings sort chronologically, so they can be compared as strings.
        switch sort {
        case .count:
            rows.sort { $0.emails != $1.emails ? $0.emails > $1.emails : ($0.first, $0.subject) < ($1.first, $1.subject) }
        case .first:
            rows.sort { ($0.first, $0.subject) < ($1.first, $1.subject) }
        case .last:
            rows.sort { ($0.last, $0.subject) > ($1.last, $1.subject) }
        case .subject:
            rows.sort { ($0.subject.lowercased(), $0.first) < ($1.subject.lowercased(), $1.first) }
        }

        switch format {
        case .table:
            printTable(rows)
        case .tsv:
            for row in rows {
                let fields = [
                    String(row.emails),
                    String(row.participants.count),
                    row.first,
                    row.last,
                    row.conversationId.map { String($0) } ?? "",
                    Self.singleLine(row.subject),
                ]
                print(fields.joined(separator: "\t"))
            }
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(rows)
            print(String(decoding: data, as: UTF8.self))
        }

        Log.info("\(rows.count) threads")
    }

    private func printTable(_ rows: [ListRow]) {
        let header = ["EMAILS", "PEOPLE", "FIRST", "LAST", "SUBJECT"]
        let body: [[String]] = rows.map { row in
            [
                String(row.emails),
                String(row.participants.count),
                String(row.first.prefix(10)),
                String(row.last.prefix(10)),
                String(Self.singleLine(row.subject).prefix(80)),
            ]
        }

        var widths = header.map { $0.count }
        for line in body {
            for (column, cell) in line.enumerated() {
                widths[column] = max(widths[column], cell.count)
            }
        }

        func render(_ cells: [String]) -> String {
            var parts: [String] = []
            for (column, cell) in cells.enumerated() {
                let padding = String(repeating: " ", count: max(0, widths[column] - cell.count))
                if column <= 1 {
                    parts.append(padding + cell)          // numbers right-aligned
                } else if column == cells.count - 1 {
                    parts.append(cell)                    // last column unpadded
                } else {
                    parts.append(cell + padding)
                }
            }
            return parts.joined(separator: "  ")
        }

        print(render(header))
        for line in body {
            print(render(line))
        }
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct ListParticipant: Encodable {
    let address: String
    let name: String?
    /// Emails this participant sent within the thread.
    let sent: Int
}

struct ListRow: Encodable {
    /// Mail's conversation id; absent for an email Mail did not assign to a conversation.
    let conversationId: Int64?
    let subject: String
    let emails: Int
    /// ISO 8601, UTC.
    let first: String
    let last: String
    /// Most active senders first.
    let participants: [ListParticipant]
}
