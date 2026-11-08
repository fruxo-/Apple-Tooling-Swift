import ArgumentParser
import Foundation

enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    case markdown
    case html
    /// Markdown and HTML files side by side.
    case both

    var kinds: [OutputKind] {
        switch self {
        case .markdown: return [.markdown]
        case .html: return [.html]
        case .both: return [.markdown, .html]
        }
    }
}

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export email threads as Markdown and/or HTML, one file per thread.",
        discussion: """
            Reads Mail's Envelope Index database (from a private temporary copy, so the live \
            database is never touched) and the .emlx message files next to it.

            Emails are grouped into threads by Mail's own conversation id. Each thread becomes one \
            file, named after its first email's UTC timestamp so files sort chronologically. \
            A file starts with the earliest and latest email timestamps, the number of emails, \
            every participant and how many emails each one sent, followed by the emails in order.

            --format chooses Markdown (default), HTML or both. HTML files are self-contained pages \
            (inline styles, no scripts, no remote content) that open in any browser; email bodies \
            are shown as plain text, with quoted replies folded behind a "Show quoted text" toggle.

            Files are written to <output>/<party>/, a subfolder named after the --party address \
            (several addresses are joined with "__"; without --party it is "all"), so different \
            people can be exported into the same output folder without mixing.

            With --party, every thread in which that address took part (as sender, To, Cc or Bcc \
            of any email) is exported in full, including emails between other people. With a date \
            window, a thread contains only its emails inside the window.

            Add --only to narrow each thread to the emails that feature the --party address in From, \
            To, Cc or Bcc (with several --party options: all of them). Emails of the same thread \
            between other people are left out, and the counts, timestamps and participants describe \
            only the emails kept. --only exports go to <output>/<party>__only/ so they never mix \
            with a full export of the same person.

            Mail's data folder is read from ~/Library/Mail/V* by default. Your terminal needs \
            Full Disk Access to read it (System Settings > Privacy & Security). \
            Use `mail-utils list` to preview what would be exported.
            """
    )

    @OptionGroup var selection: SelectionOptions

    @Option(
        name: .shortAndLong,
        help:
            "Output directory (created if needed). Files go into a subfolder named after the --party address ('__only' appended with --only), or 'all' without --party."
    )
    var output: String = "mail-export"

    @Option(help: "File format: markdown (default), html, or both (files side by side).")
    var format: ExportFormat = .markdown

    @Flag(
        name: .shortAndLong,
        help: "Print every thread written and report every email whose body could not be found.")
    var verbose = false

    func run() throws {
        let loaded = try selection.load()

        if loaded.threads.isEmpty {
            print("No matching threads found.")
            return
        }

        Log.info("Indexing .emlx files (this can take a while on large mailboxes)…")
        let index = EmlxIndex(root: loaded.location.root)
        Log.info("Found \(index.fileCount) .emlx files")

        let outputURL = URL(
            fileURLWithPath: (output as NSString).expandingTildeInPath, isDirectory: true
        )
        .appendingPathComponent(
            TextTools.folderName(forParties: loaded.parties, only: selection.only),
            isDirectory: true)
        let exporter = Exporter(
            outputDirectory: outputURL,
            locator: EmlxLocator(index: index),
            names: DisplayNames.collect(from: loaded.messages),
            formats: format.kinds,
            verbose: verbose
        )
        let summary = try exporter.export(
            loaded.threads,
            messages: loaded.messages,
            rangeDescription: loaded.rangeDescription
        )

        print(
            "Exported \(summary.emails) emails in \(summary.threads) threads (\(summary.filesWritten) files) to \(outputURL.path)"
        )
        if summary.missingBodies > 0 {
            Log.info(
                "Body not found for \(summary.missingBodies) emails (headers and snippet were written instead). Use --verbose to list them."
            )
        }
    }
}
