import ArgumentParser
import Foundation

struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check a converted vault against the ENEX export it came from.",
        discussion: """
            Counts are computed twice by independent paths — one re-parses the ENEX, the other \
            reads only the files on disk — and compared. Exits non-zero on any mismatch.
            """
    )

    @Option(
        name: [.customShort("i"), .customLong("input")],
        help: ArgumentHelp("Directory containing the source .enex files.", valueName: "enex-dir")
    )
    var input: String

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: ArgumentHelp("Directory containing the converted vault.", valueName: "vault-dir")
    )
    var output: String

    @Flag(name: .customLong("json"), help: "Emit the report as JSON.")
    var json = false

    func run() throws {
        let inputDirectory = URL(fileURLWithPath: input, isDirectory: true)
        let outputDirectory = URL(fileURLWithPath: output, isDirectory: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ValidationError("input is not a directory: \(inputDirectory.path)")
        }

        let report = try Verifier(
            inputDirectory: inputDirectory,
            outputDirectory: outputDirectory
        ).run()

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(report.textSummary())
        }

        if !report.ok {
            throw ExitCode.failure
        }
    }
}
