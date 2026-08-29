import ArgumentParser
import Foundation

struct Enexodus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enexodus",
        abstract: "Convert Evernote ENEX exports into a folder-per-notebook Markdown archive.",
        discussion: """
            Input is a directory of .enex files, one per notebook, where the filename is the \
            notebook name — ENEX itself does not record it.

            Anything ENML expresses that Markdown cannot is written as sanitized inline HTML \
            rather than approximated, so no note loses content. Run `verify` afterwards to \
            confirm the vault matches the export.
            """,
        version: "0.1.0",
        subcommands: [ConvertCommand.self, VerifyCommand.self],
        defaultSubcommand: ConvertCommand.self
    )
}

Enexodus.main()
