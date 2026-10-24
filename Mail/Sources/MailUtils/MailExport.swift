import ArgumentParser
import Foundation

@main
struct MailExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail-utils",
        abstract: "Utility tool for Apple Mail.",
        discussion: """
        Reads Mail's Envelope Index database (from a private temporary copy, so the live \
        database is never touched) and the .emlx message files next to it.

        A "correspondence" is an unordered pair of email addresses: the sender of a message \
        plus any one of its recipients (To, Cc or Bcc). Each correspondence becomes a folder; \
        each message in it becomes one Markdown file whose name starts with its UTC timestamp, \
        so files sort chronologically. A message sent to several people appears in each \
        relevant folder.

        Mail's data folder is read from ~/Library/Mail/V* by default. Your terminal needs \
        Full Disk Access to read it (System Settings > Privacy & Security).
        """
    )

    @Option(name: .shortAndLong,
            help: "Mail data directory: a version folder such as ~/Library/Mail/V10, or its parent. Defaults to the newest ~/Library/Mail/V*.")
    var mailDirectory: String?

    @Option(name: .shortAndLong,
            help: "Output directory (created if needed).")
    var output: String = "mail-export"

    @Option(help: "Only messages on or after this date. YYYY-MM-DD (local time) or an ISO 8601 date-time.")
    var from: DateInput?

    @Option(help: "Only messages on or before this date. A bare YYYY-MM-DD includes that whole day.")
    var to: DateInput?

    @Option(name: .customLong("party"),
            help: "Restrict to correspondence involving this address. Give it once to export everyone that address corresponded with; give it two or more times to export only pairs made of those addresses.")
    var parties: [String] = []

    @Option(help: "Skip correspondences with fewer than this many messages.")
    var minMessages: Int = 1

    @Flag(help: "Include messages Mail has flagged as deleted.")
    var includeDeleted = false

    @Flag(help: "List the correspondences that would be exported (count, address, address) and exit without writing anything.")
    var dryRun = false

    @Flag(name: .shortAndLong,
          help: "Report every message whose body could not be found.")
    var verbose = false

    mutating func validate() throws {
        if minMessages < 1 {
            throw ValidationError("--min-messages must be at least 1.")
        }
        if let lowerBound = from, let upperBound = to, lowerBound.date > upperBound.date {
            throw ValidationError("--from must not be later than --to.")
        }
    }

    func run() throws {
        let location = try MailLocation.resolve(override: mailDirectory)
        Log.info("Mail data: \(location.root.path)")

        // Date window as inclusive Unix-second bounds.
        var lower = Int64.min
        var upper = Int64.max
        var rangeParts: [String] = []
        if let fromValue = self.from {
            lower = Int64(fromValue.date.timeIntervalSince1970.rounded(.down))
            rangeParts.append("from \(fromValue.text)")
        }
        if let toValue = self.to {
            var end = toValue.date
            if toValue.dateOnly {
                end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(86_400)
            }
            upper = Int64(end.timeIntervalSince1970.rounded(.down)) - (toValue.dateOnly ? 1 : 0)
            rangeParts.append("to \(toValue.text)")
        }

        let snapshot: DatabaseSnapshot
        do {
            snapshot = try DatabaseSnapshot.make(from: location.databaseURL)
        } catch {
            throw ExportError.io("""
                Could not copy \(location.databaseURL.path): \(error.localizedDescription)
                If this is a permissions error, grant Full Disk Access to your terminal \
                (System Settings > Privacy & Security > Full Disk Access) and try again.
                """)
        }
        defer { snapshot.remove() }

        let database = try SQLiteConnection(path: snapshot.databaseURL.path, readOnly: false)
        let query = MailQuery(from: lower, to: upper, includeDeleted: includeDeleted)
        let messages = try MailStore.loadMessages(from: database, query: query)
        Log.info("Loaded \(messages.count) messages in range")

        let partySet = Set(
            parties
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        let correspondences = Correspondence.build(from: messages, parties: partySet, minMessages: minMessages)

        if correspondences.isEmpty {
            print("No matching correspondence found.")
            return
        }

        if dryRun {
            let sorted = correspondences.sorted {
                $0.messageIndexes.count != $1.messageIndexes.count
                    ? $0.messageIndexes.count > $1.messageIndexes.count
                    : $0.key < $1.key
            }
            for item in sorted {
                print("\(item.messageIndexes.count)\t\(item.key.first)\t\(item.key.second)")
            }
            Log.info("\(correspondences.count) correspondences (dry run, nothing written)")
            return
        }

        Log.info("Indexing .emlx files (this can take a while on large mailboxes)…")
        let index = EmlxIndex(root: location.root)
        Log.info("Found \(index.fileCount) .emlx files")

        let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath, isDirectory: true)
        let exporter = Exporter(
            outputDirectory: outputURL,
            locator: EmlxLocator(index: index),
            names: Correspondence.collectNames(from: messages),
            verbose: verbose
        )
        let summary = try exporter.export(
            correspondences,
            messages: messages,
            rangeDescription: rangeParts.isEmpty ? nil : rangeParts.joined(separator: " ")
        )

        print("""
            Exported \(summary.filesWritten) message files in \(summary.correspondences) correspondences to \(outputURL.path)
            """)
        if summary.missingBodies > 0 {
            Log.info("Body not found for \(summary.missingBodies) files (header details and snippet were written instead). Use --verbose to list them.")
        }
    }
}

/// A `--from` / `--to` value.
struct DateInput: ExpressibleByArgument {
    let date: Date
    let dateOnly: Bool
    let text: String

    init?(argument: String) {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)

        let iso = ISO8601DateFormatter()
        let optionSets: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
        ]
        for options in optionSets {
            iso.formatOptions = options
            if let parsed = iso.date(from: trimmed) {
                self.date = parsed
                self.dateOnly = false
                self.text = trimmed
                return
            }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let formats: [(String, Bool)] = [
            ("yyyy-MM-dd'T'HH:mm:ss", false),
            ("yyyy-MM-dd'T'HH:mm", false),
            ("yyyy-MM-dd HH:mm:ss", false),
            ("yyyy-MM-dd HH:mm", false),
            ("yyyy-MM-dd", true),
        ]
        for (format, only) in formats {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: trimmed) {
                self.date = parsed
                self.dateOnly = only
                self.text = trimmed
                return
            }
        }
        return nil
    }
}
