import Foundation
import XCTest

@testable import enexodus

final class EndToEndTests: XCTestCase {

    // MARK: Golden output

    func testConvertedVaultMatchesExpectedTreeByteForByte() throws {
        let output = try makeTemporaryDirectory(self)
        try convertFixtures(into: output)

        let produced = try fileTree(at: output)
        let expected = try fileTree(at: Fixtures.expectedDirectory)
        XCTAssertEqual(produced, expected, "vault tree differs from Tests/Fixtures/expected")

        for path in expected {
            let actualData = try Data(contentsOf: output.appendingPathComponent(path))
            let expectedData = try Data(
                contentsOf: Fixtures.expectedDirectory.appendingPathComponent(path)
            )
            if actualData == expectedData { continue }

            // Show the diff as text when both sides are text; otherwise report the byte counts.
            if let actual = String(data: actualData, encoding: .utf8),
                let expected = String(data: expectedData, encoding: .utf8)
            {
                XCTFail("\(path) differs\n--- expected ---\n\(expected)\n--- actual ---\n\(actual)")
            } else {
                XCTFail("\(path) differs (\(expectedData.count) vs \(actualData.count) bytes)")
            }
        }
    }

    // MARK: Idempotency (plan §6.3)

    func testConvertingTwiceIntoTheSameDirectoryChangesNothing() throws {
        let output = try makeTemporaryDirectory(self)
        try convertFixtures(into: output)

        var firstRun: [String: Data] = [:]
        for path in try fileTree(at: output) {
            firstRun[path] = try Data(contentsOf: output.appendingPathComponent(path))
        }

        try convertFixtures(into: output)

        let secondPaths = try fileTree(at: output)
        XCTAssertEqual(secondPaths.sorted(), firstRun.keys.sorted(), "a re-run changed the tree")
        for path in secondPaths {
            let after = try Data(contentsOf: output.appendingPathComponent(path))
            XCTAssertEqual(after, firstRun[path], "\(path) changed on the second run")
        }
    }

    func testConvertingIntoTwoSeparateDirectoriesProducesIdenticalOutput() throws {
        let first = try makeTemporaryDirectory(self)
        let second = try makeTemporaryDirectory(self)
        try convertFixtures(into: first)
        try convertFixtures(into: second)

        let paths = try fileTree(at: first)
        XCTAssertEqual(paths, try fileTree(at: second))
        for path in paths {
            XCTAssertEqual(
                try Data(contentsOf: first.appendingPathComponent(path)),
                try Data(contentsOf: second.appendingPathComponent(path)),
                "\(path) is not reproducible"
            )
        }
    }

    // MARK: Verification (plan §6.4)

    func testVerifyPassesOnAFreshlyConvertedVault() throws {
        let output = try makeTemporaryDirectory(self)
        try convertFixtures(into: output)

        let report = try Verifier(
            inputDirectory: Fixtures.directory, outputDirectory: output
        ).run()

        XCTAssertTrue(report.ok, "verify reported: \(report.notebooks.flatMap(\.problems))")
        XCTAssertEqual(report.totals.notebooks, 5)
        XCTAssertEqual(report.totals.enexNotes, 19)
        XCTAssertEqual(report.totals.markdownFiles, 19)
        XCTAssertEqual(report.totals.enexResources, 2)
        XCTAssertEqual(report.totals.attachmentFiles, 2)
        XCTAssertEqual(report.totals.enexMediaReferences, 3)
        XCTAssertEqual(report.totals.vaultMediaReferences, 3)
        XCTAssertEqual(report.totals.orphanMediaReferences, 1)
        XCTAssertEqual(report.totals.emptyBodyNotes, 1)
        XCTAssertEqual(report.totals.fallbackBlocks, 3)
    }

    /// The ENEX-side and vault-side counts must be produced by different code. This checks the
    /// vault side against a hand-rolled count taken straight off the filesystem.
    func testVerifyVaultCountsAgreeWithAnIndependentFilesystemWalk() throws {
        let output = try makeTemporaryDirectory(self)
        try convertFixtures(into: output)
        let report = try Verifier(
            inputDirectory: Fixtures.directory, outputDirectory: output
        ).run()

        var markdownFiles = 0
        var attachmentFiles = 0
        for path in try fileTree(at: output) {
            if path.contains("/\(VaultWriter.attachmentsDirectoryName)/") {
                attachmentFiles += 1
            } else if path.hasSuffix(".md") {
                markdownFiles += 1
            }
        }
        XCTAssertEqual(report.totals.markdownFiles, markdownFiles)
        XCTAssertEqual(report.totals.attachmentFiles, attachmentFiles)
    }

    func testVerifyFailsWithTheCorrectDeltaWhenANoteIsDeleted() throws {
        let output = try makeTemporaryDirectory(self)
        try convertFixtures(into: output)
        try FileManager.default.removeItem(
            at: output.appendingPathComponent("plain/Meeting notes.md")
        )

        let report = try Verifier(
            inputDirectory: Fixtures.directory, outputDirectory: output
        ).run()

        XCTAssertFalse(report.ok)
        let plain = try XCTUnwrap(report.notebooks.first { $0.notebook == "plain" })
        XCTAssertEqual(plain.enexNotes, 3)
        XCTAssertEqual(plain.markdownFiles, 2)
        XCTAssertTrue(plain.problems.contains { $0.contains("3 in ENEX, 2 .md files") })

        // Untouched notebooks must stay clean.
        let todos = try XCTUnwrap(report.notebooks.first { $0.notebook == "todos" })
        XCTAssertTrue(todos.ok)
    }

    func testVerifyFailsWhenAnAttachmentIsDeleted() throws {
        let output = try makeTemporaryDirectory(self)
        try convertFixtures(into: output)
        try FileManager.default.removeItem(
            at: output.appendingPathComponent(
                "media/\(VaultWriter.attachmentsDirectoryName)/diagram.png"
            )
        )

        let report = try Verifier(
            inputDirectory: Fixtures.directory, outputDirectory: output
        ).run()

        XCTAssertFalse(report.ok)
        let media = try XCTUnwrap(report.notebooks.first { $0.notebook == "media" })
        XCTAssertEqual(media.enexResources, 2)
        XCTAssertEqual(media.attachmentFiles, 1)
        XCTAssertTrue(media.problems.contains { $0.contains("attachment count mismatch") })
        XCTAssertTrue(media.problems.contains { $0.contains("missing attachment") })
    }

    func testVerifyReportIsEncodableAsJSON() throws {
        let output = try makeTemporaryDirectory(self)
        try convertFixtures(into: output)
        let report = try Verifier(
            inputDirectory: Fixtures.directory, outputDirectory: output
        ).run()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(VerificationReport.self, from: data)
        XCTAssertEqual(decoded.totals.enexNotes, report.totals.enexNotes)
        XCTAssertTrue(decoded.ok)
    }

    // MARK: End-to-end losslessness

    /// The whole pipeline, not just the renderer: ENEX on disk through to Markdown on disk.
    /// Each note's source text must survive into the file that was written for it.
    func testNoNoteLosesTextThroughTheFullPipeline() throws {
        let output = try makeTemporaryDirectory(self)

        for location in try VaultWriter.locations(inInputDirectory: Fixtures.directory) {
            let writer = try VaultWriter(
                outputRoot: output,
                directoryName: location.directoryName,
                notebookName: location.notebookName,
                sourceFileName: location.fileURL.lastPathComponent,
                clean: false
            )
            let directory = output.appendingPathComponent(location.directoryName)

            try ENEXParser.parse(fileURL: location.fileURL) { note in
                let outcome = try writer.write(note)
                guard let tree = try? ENMLDocument.parse(note.content) else { return }
                let written = try String(
                    contentsOf: directory.appendingPathComponent(outcome.fileName),
                    encoding: .utf8
                )
                let missing = Losslessness.firstMissing(
                    Losslessness.sourceText(tree),
                    in: Losslessness.outputText(written)
                )
                XCTAssertNil(
                    missing,
                    "\(location.notebookName)/\(outcome.fileName) lost text: \(missing ?? "")"
                )
            }
        }
    }
}
