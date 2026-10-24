import ArgumentParser

// The type is deliberately not called `MailUtils`: a type sharing its module's name makes
// qualified name lookups ambiguous.
@main
struct MailUtilsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail-utils",
        abstract: "Utility tool for Apple Mail.",
        subcommands: [ExportCommand.self, ListCommand.self]
    )
}
