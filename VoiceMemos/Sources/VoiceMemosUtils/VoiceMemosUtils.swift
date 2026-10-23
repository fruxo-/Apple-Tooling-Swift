import ArgumentParser
import Foundation
import VoiceMemosKit

/// A calendar day given on the command line as `YYYY-MM-DD` (local time zone).
struct CalendarDay: ExpressibleByArgument {
    let date: Date

    init?(argument: String) {
        guard let parsed = DayParser.parse(argument) else { return nil }
        date = parsed
    }
}

/// Keeps a description on a single line so the `Description:` / `Path:` layout stays intact.
private func singleLine(_ text: String) -> String {
    String(text.map { $0.isNewline ? " " : $0 })
}

@main
struct VoiceMemosUtils: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vmsearch",
        abstract: "Find Voice Memos recordings by date, date range and title keywords.",
        discussion: """
            Prints the path of each matching audio file, one per line, oldest first, \
            which is ideal for scripting. With --describe, each match is printed as a \
            "Description:" line (the recording's title, as shown and editable in Voice \
            Memos) followed by a "Path:" line, with a blank line between recordings.

            --search matches the recording title against a boolean expression. Terms are \
            case- and accent-insensitive substrings; combine them with and / or and group \
            them with parentheses. "and" binds tighter than "or", so use parentheses when \
            mixing them. Put phrases that contain spaces in double quotes ("team meeting"); \
            a quoted "and" or "or" is an ordinary term. Adjacent terms need an explicit \
            operator. Wrap the whole expression in single quotes so your shell leaves it alone.

            Examples:
              vmsearch --date 2026-10-23
              vmsearch --from 2026-10-01 --to 2026-10-31
              vmsearch --search 'meeting and budget'
              vmsearch --search 'idea or lyrics or melody'
              vmsearch --search '(foo and bar) or (alice and bob)'
              vmsearch --from 2026-01-01 --search '"team meeting" and (budget or roadmap)'
            """
    )

    // MARK: Date filters

    @Option(help: ArgumentHelp("Recordings made on exactly this day.", valueName: "YYYY-MM-DD"))
    var date: CalendarDay?

    @Option(help: ArgumentHelp("Recordings made on or after this day.", valueName: "YYYY-MM-DD"))
    var from: CalendarDay?

    @Option(help: ArgumentHelp("Recordings made on or before this day.", valueName: "YYYY-MM-DD"))
    var to: CalendarDay?

    // MARK: Title filter

    @Option(
        name: [.customLong("search"), .customShort("s")],
        help: ArgumentHelp(
            "Boolean expression matched against the title, e.g. '(foo and bar) or (alice and bob)'.",
            valueName: "expression"))
    var search: String?

    // MARK: Options

    @Option(name: .customLong("db"), help: "Path to CloudRecordings.db.")
    var databasePath: String = VoiceMemosLibrary.defaultDatabaseURL.path

    @Flag(
        name: [.customLong("describe"), .customShort("d")],
        help: "Print each match as \"Description: <title>\" followed by \"Path: <path>\" instead of just the path.")
    var describe = false

    @Flag(help: "Also list recordings whose audio file isn't on disk (e.g. evicted to iCloud).")
    var includeMissing = false

    // MARK: Run

    mutating func validate() throws {
        if date != nil && (from != nil || to != nil) {
            throw ValidationError("--date cannot be combined with --from or --to.")
        }
        if let from, let to, from.date > to.date {
            throw ValidationError("--from must not be later than --to.")
        }
        if let search {
            do {
                _ = try SearchExpression.parse(search)
            } catch {
                throw ValidationError("Invalid --search expression: \(error.localizedDescription)")
            }
        }
    }

    mutating func run() throws {
        let dateFilter: DateFilter
        if let date {
            dateFilter = .day(date.date)
        } else if from != nil || to != nil {
            dateFilter = .range(from: from?.date, to: to?.date)
        } else {
            dateFilter = .unrestricted
        }

        let criteria = SearchCriteria(
            date: dateFilter,
            titleExpression: try search.map { try SearchExpression.parse($0) }
        )
        let library = VoiceMemosLibrary(
            databaseURL: URL(fileURLWithPath: (databasePath as NSString).expandingTildeInPath)
        )

        var skipped = 0
        var printed = 0
        for recording in try library.search(criteria) {
            guard includeMissing || recording.audioFileExists else {
                skipped += 1
                continue
            }
            let path = recording.audioURL.path
            if describe {
                if printed > 0 { print("") }
                print("Description: \(singleLine(recording.displayName))")
                print("Path: \(path)")
            } else {
                print(path)
            }
            printed += 1
        }

        if skipped > 0 {
            let note =
                "vmsearch: skipped \(skipped) matching recording(s) whose audio file isn't on disk "
                + "(possibly evicted to iCloud). Use --include-missing to list them anyway.\n"
            FileHandle.standardError.write(Data(note.utf8))
        }
    }
}