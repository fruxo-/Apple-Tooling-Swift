import ArgumentParser
import Foundation

/// Options that decide *which* correspondence is selected. Shared by `export` and `list`.
struct SelectionOptions: ParsableArguments {
    @Option(
        name: .shortAndLong,
        help:
            "Mail data directory: a version folder such as ~/Library/Mail/V10, or its parent. Defaults to the newest ~/Library/Mail/V*."
    )
    var mailDirectory: String?

    @Option(
        help:
            "Only emails on or after this date. YYYY-MM-DD (local time) or an ISO 8601 date-time. Threads keep only their emails inside the window."
    )
    var from: DateInput?

    @Option(help: "Only emails on or before this date. A bare YYYY-MM-DD includes that whole day.")
    var to: DateInput?

    @Option(
        name: .customLong("party"),
        help:
            "Only threads in which this address took part, as sender, To, Cc or Bcc of any email. Give it more than once to require all of those addresses."
    )
    var parties: [String] = []

    @Flag(
        help:
            "With --party: within each thread, keep only the emails that feature the party address in From, To, Cc or Bcc (with several --party options, an email must feature all of them). Counts, timestamps and participants then describe just those emails."
    )
    var only = false

    @Option(help: "Skip threads with fewer than this many emails.")
    var minMessages: Int = 1

    @Flag(help: "Include messages Mail has flagged as deleted.")
    var includeDeleted = false

    mutating func validate() throws {
        if only && parties.isEmpty {
            throw ValidationError("--only needs at least one --party.")
        }
        if minMessages < 1 {
            throw ValidationError("--min-messages must be at least 1.")
        }
        if let lowerBound = from, let upperBound = to, lowerBound.date > upperBound.date {
            throw ValidationError("--from must not be later than --to.")
        }
    }
}

/// Everything the subcommands need once the database has been read.
struct LoadedMail {
    let location: MailLocation
    /// Chronological, de-duplicated.
    let messages: [Message]
    let threads: [MailThread]
    /// The --party addresses, lowercased, de-duplicated and sorted.
    let parties: [String]
    let rangeDescription: String?
}

extension SelectionOptions {
    /// Resolves the Mail folder, reads a private copy of the Envelope Index and builds the threads.
    func load() throws -> LoadedMail {
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
                end =
                    Calendar.current.date(byAdding: .day, value: 1, to: end)
                    ?? end.addingTimeInterval(86_400)
            }
            upper = Int64(end.timeIntervalSince1970.rounded(.down)) - (toValue.dateOnly ? 1 : 0)
            rangeParts.append("to \(toValue.text)")
        }

        let snapshot: DatabaseSnapshot
        do {
            snapshot = try DatabaseSnapshot.make(from: location.databaseURL)
        } catch {
            throw ExportError.io(
                """
                Could not copy \(location.databaseURL.path): \(error.localizedDescription)
                If this is a permissions error, grant Full Disk Access to your terminal \
                (System Settings > Privacy & Security > Full Disk Access) and try again.
                """)
        }
        defer { snapshot.remove() }

        let database = try SQLiteConnection(path: snapshot.databaseURL.path, readOnly: false)
        let query = MailQuery(from: lower, to: upper, includeDeleted: includeDeleted)
        var messages = try MailStore.loadMessages(from: database, query: query)
        Log.info("Loaded \(messages.count) messages in range")

        let partySet = Set(
            parties
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )

        if only {
            // Narrow to the emails that feature every --party address in From, To, Cc or Bcc.
            messages = messages.filter { partySet.isSubset(of: $0.involvedAddresses) }
            Log.info(
                "Kept \(messages.count) emails featuring \(partySet.sorted().joined(separator: ", "))"
            )
        }

        let threads = MailThread.build(from: messages, parties: partySet, minMessages: minMessages)

        return LoadedMail(
            location: location,
            messages: messages,
            threads: threads,
            parties: partySet.sorted(),
            rangeDescription: rangeParts.isEmpty ? nil : rangeParts.joined(separator: " ")
        )
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
