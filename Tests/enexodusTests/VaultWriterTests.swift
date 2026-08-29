import Foundation
import XCTest

@testable import enexodus

final class VaultWriterTests: XCTestCase {

    // MARK: Slugs

    func testSlugRefusesPathTraversal() {
        for hostile in [
            "../../etc/passwd",
            "..\\..\\windows\\system32",
            "/absolute/path",
            "./relative",
            "..",
            ".",
            "....//....//etc",
        ] {
            let slug = Slug.make(hostile)
            XCTAssertFalse(slug.contains("/"), "\(hostile) -> \(slug)")
            XCTAssertFalse(slug.contains("\\"), "\(hostile) -> \(slug)")
            XCTAssertFalse(slug.hasPrefix("."), "\(hostile) -> \(slug)")
            XCTAssertNotEqual(slug, "..")
            XCTAssertFalse(slug.isEmpty)
            // The decisive property: appending it cannot leave the parent directory.
            let base = URL(fileURLWithPath: "/vault/notebook", isDirectory: true)
            let resolved = base.appendingPathComponent(slug).standardizedFileURL.path
            XCTAssertTrue(
                resolved.hasPrefix("/vault/notebook/"),
                "\(hostile) escaped to \(resolved)"
            )
        }
    }

    func testSlugStripsControlCharactersAndFilesystemReservedCharacters() {
        XCTAssertEqual(Slug.make("a\u{0}b"), "a-b")
        XCTAssertEqual(Slug.make("line\nbreak"), "line break")
        XCTAssertEqual(Slug.make("tab\there"), "tab here")
        XCTAssertEqual(Slug.make("a:b*c?d\"e<f>g|h"), "a-b-c-d-e-f-g-h")
    }

    func testSlugKeepsUnicodeAndTruncatesOnCharacterBoundaries() {
        XCTAssertEqual(Slug.make("Café 🚀"), "Café 🚀")

        let long = String(repeating: "é", count: 300)
        let slug = Slug.make(long)
        XCTAssertEqual(slug.count, Slug.maxLength)
        XCTAssertTrue(slug.allSatisfy { $0 == "é" }, "truncation split a character")
    }

    func testSlugFallsBackWhenNothingSurvives() {
        XCTAssertEqual(Slug.make(""), "untitled")
        XCTAssertEqual(Slug.make("..."), "untitled")
        XCTAssertEqual(Slug.make("///"), "untitled")
        XCTAssertEqual(Slug.make("", fallback: "note"), "note")
    }

    func testDisambiguationIsCaseInsensitive() {
        var used: Set<String> = []
        XCTAssertEqual(Slug.disambiguate("Note", extension: "md", used: &used), "Note.md")
        XCTAssertEqual(Slug.disambiguate("note", extension: "md", used: &used), "note-2.md")
        XCTAssertEqual(Slug.disambiguate("NOTE", extension: "md", used: &used), "NOTE-3.md")
    }

    // MARK: Frontmatter

    func testFrontmatterQuotesAndEscapes() {
        XCTAssertEqual(Frontmatter.quoted("plain"), "\"plain\"")
        XCTAssertEqual(Frontmatter.quoted("say \"hi\""), "\"say \\\"hi\\\"\"")
        XCTAssertEqual(Frontmatter.quoted("back\\slash"), "\"back\\\\slash\"")
        XCTAssertEqual(Frontmatter.quoted("key: value"), "\"key: value\"")
        XCTAssertEqual(Frontmatter.quoted("line\nbreak"), "\"line\\nbreak\"")
        XCTAssertEqual(Frontmatter.quoted("🚀 emoji"), "\"🚀 emoji\"")
    }

    func testTagScalarsQuoteOnlyWhenNecessary() {
        XCTAssertEqual(Frontmatter.scalar("work"), "work")
        XCTAssertEqual(Frontmatter.scalar("two words"), "two words")
        XCTAssertEqual(Frontmatter.scalar("needs: review"), "\"needs: review\"")
        XCTAssertEqual(Frontmatter.scalar("a,b"), "\"a,b\"")
        XCTAssertEqual(Frontmatter.scalar("[bracket]"), "\"[bracket]\"")
        XCTAssertEqual(Frontmatter.scalar("true"), "\"true\"")
        XCTAssertEqual(Frontmatter.scalar("2024"), "\"2024\"")
        XCTAssertEqual(Frontmatter.scalar("#tag"), "\"#tag\"")
        XCTAssertEqual(Frontmatter.scalar(""), "\"\"")
    }

    func testFrontmatterFieldOrderAndOptionalFields() throws {
        let notes = try Fixtures.notes(in: "plain")
        let withSource = Frontmatter.render(
            note: notes[1], notebook: "plain", sourceFile: "plain.enex"
        )
        XCTAssertEqual(
            withSource.components(separatedBy: "\n"),
            [
                "---",
                "title: \"Links and formatting\"",
                "created: 2020-01-15T10:15:00Z",
                "updated: 2020-01-15T10:15:00Z",
                "tags: []",
                "source-url: \"https://example.com/source\"",
                "notebook: \"plain\"",
                "enex-source: \"plain.enex\"",
                "---",
            ]
        )

        let withoutSource = Frontmatter.render(
            note: notes[0], notebook: "plain", sourceFile: "plain.enex"
        )
        XCTAssertFalse(withoutSource.contains("source-url"))
        XCTAssertTrue(withoutSource.contains("tags: [work, meetings]"))
    }

    // MARK: Writing

    private func write(_ fixture: String, into output: URL) throws -> [NoteOutcome] {
        let writer = try VaultWriter(
            outputRoot: output,
            directoryName: fixture,
            notebookName: fixture,
            sourceFileName: "\(fixture).enex",
            clean: false
        )
        var outcomes: [NoteOutcome] = []
        try ENEXParser.parse(fileURL: Fixtures.url(fixture)) { outcomes.append(try writer.write($0)) }
        return outcomes
    }

    func testHostileTitlesProduceSafeUniqueFilenames() throws {
        let output = try makeTemporaryDirectory(self)
        let outcomes = try write("hostile", into: output)

        XCTAssertEqual(outcomes.count, 7, "no note may be dropped")
        XCTAssertEqual(outcomes[0].fileName, "etc-passwd.md")
        XCTAssertEqual(outcomes[2].fileName, "Duplicate title.md")
        XCTAssertEqual(outcomes[3].fileName, "Duplicate title-2.md")

        for outcome in outcomes {
            XCTAssertFalse(outcome.fileName.contains("/"))
            XCTAssertLessThanOrEqual(outcome.fileName.count, Slug.maxLength + 5)
        }
        let names = Set(outcomes.map(\.fileName))
        XCTAssertEqual(names.count, outcomes.count, "filenames must be unique")

        // Nothing may be written outside the notebook directory.
        let stray = output.appendingPathComponent("etc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    func testAttachmentNamingAndDeduplication() throws {
        let output = try makeTemporaryDirectory(self)
        let outcomes = try write("media", into: output)

        XCTAssertEqual(outcomes[0].attachmentsWritten, ["diagram.png", "1bbc324f.pdf"])
        XCTAssertTrue(outcomes[1].attachmentsWritten.isEmpty)

        let attachments = output
            .appendingPathComponent("media")
            .appendingPathComponent(VaultWriter.attachmentsDirectoryName)
        let files = try FileManager.default.contentsOfDirectory(atPath: attachments.path).sorted()
        XCTAssertEqual(files, ["1bbc324f.pdf", "diagram.png"])

        let png = try Data(contentsOf: attachments.appendingPathComponent("diagram.png"))
        XCTAssertEqual(MD5.hexDigest(png), "b357a19c87624c7c4d131aeeb4ae677f")
    }

    func testIdenticalResourcesAreWrittenOnce() throws {
        let output = try makeTemporaryDirectory(self)
        let writer = try VaultWriter(
            outputRoot: output, directoryName: "n", notebookName: "n",
            sourceFileName: "n.enex", clean: false
        )
        let bytes = Data("same bytes".utf8)
        let resource = Resource(
            data: bytes, mime: "image/png", md5: MD5.hexDigest(bytes),
            fileName: "shared.png", sourceURL: nil
        )
        let note = Note(
            title: "Two references", content: "<en-note><div>x</div></en-note>",
            created: nil, updated: nil, tags: [], attributes: [:],
            resources: [resource, resource]
        )
        let outcome = try writer.write(note)
        XCTAssertEqual(outcome.attachmentsWritten, ["shared.png"])
    }

    func testNoAttachmentsDirectoryWhenNotebookHasNoResources() throws {
        let output = try makeTemporaryDirectory(self)
        _ = try write("plain", into: output)
        let attachments = output
            .appendingPathComponent("plain")
            .appendingPathComponent(VaultWriter.attachmentsDirectoryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachments.path))
    }

    func testEmptyNoteWritesFrontmatterOnly() throws {
        let output = try makeTemporaryDirectory(self)
        let outcomes = try write("hostile", into: output)
        let empty = try XCTUnwrap(outcomes.first { $0.title == "Empty body" })
        XCTAssertTrue(empty.isBodyEmpty)

        let text = try String(
            contentsOf: output.appendingPathComponent("hostile/\(empty.fileName)"),
            encoding: .utf8
        )
        XCTAssertTrue(text.hasSuffix("---\n"))
        XCTAssertTrue(Verifier.hasEmptyBody(text))
    }

    func testCleanRemovesStaleFiles() throws {
        let output = try makeTemporaryDirectory(self)
        _ = try write("plain", into: output)
        let stale = output.appendingPathComponent("plain/stale.md")
        try Data("stale".utf8).write(to: stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))

        let writer = try VaultWriter(
            outputRoot: output, directoryName: "plain", notebookName: "plain",
            sourceFileName: "plain.enex", clean: true
        )
        try ENEXParser.parse(fileURL: Fixtures.url("plain")) { _ = try writer.write($0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    // MARK: Layout

    /// A single .enex file is one notebook. Requiring a directory forced callers to build a
    /// throwaway folder just to convert one export.
    func testSingleFileInputResolvesToOneNotebook() throws {
        let locations = try VaultWriter.locations(inInputDirectory: Fixtures.url("plain"))
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations[0].notebookName, "plain")
        XCTAssertEqual(locations[0].directoryName, "plain")
    }

    func testNonEnexFileInputResolvesToNothing() throws {
        let directory = try makeTemporaryDirectory(self)
        let stray = directory.appendingPathComponent("notes.txt")
        try Data("not an export".utf8).write(to: stray)
        XCTAssertTrue(try VaultWriter.locations(inInputDirectory: stray).isEmpty)
    }

    func testMissingInputThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/nowhere.enex")
        XCTAssertThrowsError(try VaultWriter.locations(inInputDirectory: missing))
    }

    func testNotebookDirectoryNamesComeFromFilenames() throws {
        let locations = try VaultWriter.locations(inInputDirectory: Fixtures.directory)
        XCTAssertEqual(locations.map(\.notebookName), Fixtures.names)
        XCTAssertEqual(locations.map(\.directoryName), Fixtures.names)
        XCTAssertTrue(
            locations.allSatisfy { $0.fileURL.pathExtension == "enex" },
            "the expected/ subdirectory must not be treated as a notebook"
        )
    }
}
