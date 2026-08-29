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
        help: ArgumentHelp(
            "The .enex file or directory the vault came from. Repeat to pass several.",
            valueName: "enex-path"
        )
    )
    var input: [String] = []

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: ArgumentHelp("Directory containing the converted vault.", valueName: "vault-dir")
    )
    var output: String

    @Flag(name: .customLong("json"), help: "Emit the report as JSON.")
    var json = false

    func run() throws {
        guard !input.isEmpty else { throw ValidationError("at least one --input is required") }
        let inputs = input.map { URL(fileURLWithPath: $0) }
        let outputDirectory = URL(fileURLWithPath: output, isDirectory: true)

        for url in inputs where !FileManager.default.fileExists(atPath: url.path) {
            throw ValidationError("no such file or directory: \(url.path)")
        }

        let report = try Verifier(inputs: inputs, outputDirectory: outputDirectory).run()

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
