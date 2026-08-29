import ArgumentParser
import Foundation

struct ConvertCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert a directory of .enex files into a folder-per-notebook Markdown vault."
    )

    @Option(
        name: [.customShort("i"), .customLong("input")],
        help: ArgumentHelp("A .enex file, or a directory of them.", valueName: "enex-path")
    )
    var input: String

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: ArgumentHelp("Directory to write the vault into.", valueName: "vault-dir")
    )
    var output: String

    @Flag(
        name: .customLong("clean"),
        help: "Delete each target notebook directory before writing it."
    )
    var clean = false

    @Option(
        name: .customLong("spacing"),
        help: ArgumentHelp(
            "How to treat Evernote's blank-line spacers: 'tight' (default) drops them in "
                + "notes that put a blank line after every single line; 'faithful' keeps every one.",
            valueName: "faithful|tight"
        )
    )
    var spacing: MarkdownRenderer.Spacing = .tight

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Print only the summary.")
    var quiet = false

    func run() throws {
        let fileManager = FileManager.default
        let inputDirectory = URL(fileURLWithPath: input)
        let outputDirectory = URL(fileURLWithPath: output, isDirectory: true)

        guard fileManager.fileExists(atPath: inputDirectory.path) else {
            throw ValidationError("no such file or directory: \(inputDirectory.path)")
        }
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let locations = try VaultWriter.locations(inInputDirectory: inputDirectory)
        guard !locations.isEmpty else {
            throw ValidationError("no .enex files found at \(inputDirectory.path)")
        }

        var totalNotes = 0
        var totalAttachments = 0
        var totalOrphans = 0
        var totalFallbacks = 0
        var totalEmpty = 0
        var parseFailures = 0

        for location in locations {
            let writer = try VaultWriter(
                outputRoot: outputDirectory,
                directoryName: location.directoryName,
                notebookName: location.notebookName,
                sourceFileName: location.fileURL.lastPathComponent,
                clean: clean,
                spacing: spacing
            )

            var notebookNotes = 0
            var notebookAttachments = 0
            var notebookOrphans = 0
            var notebookFallbacks = 0
            var notebookEmpty = 0
            var notebookParseFailures = 0

            try ENEXParser.parse(fileURL: location.fileURL) { note in
                let outcome = try writer.write(note)
                notebookNotes += 1
                notebookAttachments += outcome.attachmentsWritten.count
                notebookOrphans += outcome.orphanMediaReferences
                notebookFallbacks += outcome.fallbackBlocks
                if outcome.isBodyEmpty { notebookEmpty += 1 }
                if outcome.warnings.contains(where: { $0.kind == .enmlParseFailure }) {
                    notebookParseFailures += 1
                    if !quiet {
                        FileHandle.standardError.write(
                            Data(
                                "  warning: \(location.notebookName)/\(outcome.fileName): ENML would not parse; wrote sanitized HTML instead\n"
                                    .utf8
                            )
                        )
                    }
                }
            }

            if !quiet {
                print(
                    "\(location.notebookName): \(notebookNotes) notes, "
                        + "\(notebookAttachments) attachments, "
                        + "\(notebookFallbacks) html-fallback, "
                        + "\(notebookOrphans) orphan media, "
                        + "\(notebookEmpty) empty"
                )
            }

            totalNotes += notebookNotes
            totalAttachments += notebookAttachments
            totalOrphans += notebookOrphans
            totalFallbacks += notebookFallbacks
            totalEmpty += notebookEmpty
            parseFailures += notebookParseFailures
        }

        print(
            "converted \(totalNotes) notes across \(locations.count) notebooks into \(outputDirectory.path)"
        )
        print(
            "attachments: \(totalAttachments)  html-fallback blocks: \(totalFallbacks)  "
                + "orphan media: \(totalOrphans)  empty notes: \(totalEmpty)  "
                + "unparseable ENML: \(parseFailures)"
        )
        print("run `enexodus verify --input \(input) --output \(output)` to confirm.")
    }
}

extension MarkdownRenderer.Spacing: ExpressibleByArgument {}
