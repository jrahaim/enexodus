import ArgumentParser
import Foundation

struct Enexodus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enexodus",
        abstract: "Convert Evernote ENEX exports into a folder-per-notebook Markdown archive.",
        discussion: """
            Input is one or more .enex files, or directories of them. ENEX does not record \
            which notebook a note came from, so the filename is taken as the notebook name — \
            export one notebook at a time, named after the notebook.

            Evernote splits exports over 100 notes into "Name.enex", "Name (1).enex" and so on; \
            those are merged back into a single notebook folder.

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
