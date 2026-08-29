import Foundation
import XCTest

@testable import enexodus

final class ENEXParserTests: XCTestCase {

    // MARK: Counts

    func testNoteCountsPerFixture() throws {
        let expected = ["plain": 3, "todos": 3, "tables": 3, "media": 2, "hostile": 7]
        for (fixture, count) in expected {
            let notes = try Fixtures.notes(in: fixture)
            XCTAssertEqual(notes.count, count, "note count for \(fixture).enex")
        }
    }

    func testHostileFixtureParsesWithoutCrashing() throws {
        let notes = try Fixtures.notes(in: "hostile")
        XCTAssertEqual(notes.count, 7)
        XCTAssertEqual(notes[0].title, "../../etc/passwd")
        XCTAssertTrue(notes[1].title.hasPrefix("\u{1F680} Retrospective"))
        XCTAssertEqual(notes[2].title, notes[3].title)
        XCTAssertTrue(
            notes[4].content.contains("<en-note></en-note>")
                || notes[4].content.contains("<en-note/>")
        )
    }

    // MARK: Fields

    func testTagsPreserveOrderAndDropDuplicates() throws {
        let notes = try Fixtures.notes(in: "plain")
        XCTAssertEqual(notes[0].tags, ["work", "meetings"])
        XCTAssertEqual(notes[1].tags, [])
        XCTAssertEqual(notes[2].tags, ["lists"])
    }

    func testNoteAttributesArePassedThrough() throws {
        let notes = try Fixtures.notes(in: "plain")
        XCTAssertEqual(notes[0].attributes["author"], "Jay")
        XCTAssertEqual(notes[1].sourceURL, "https://example.com/source")
        XCTAssertNil(notes[0].sourceURL)
    }

    func testDatesParseAsUTC() throws {
        let notes = try Fixtures.notes(in: "plain")
        let created = try XCTUnwrap(notes[0].created)
        let updated = try XCTUnwrap(notes[0].updated)
        XCTAssertEqual(ENEXDate.iso8601(created), "2019-04-02T14:31:00Z")
        XCTAssertEqual(ENEXDate.iso8601(updated), "2023-11-19T09:02:00Z")
    }

    func testMalformedDateYieldsNilRatherThanWrongDate() {
        XCTAssertNil(ENEXDate.parse("not-a-date"))
        XCTAssertNil(ENEXDate.parse(""))
        XCTAssertNotNil(ENEXDate.parse("20190402T143100Z"))
    }

    // MARK: Resources

    func testResourceHashesMatchDecodedBytes() throws {
        let notes = try Fixtures.notes(in: "media")
        let resources = notes[0].resources
        XCTAssertEqual(resources.count, 2)

        let png = resources[0]
        XCTAssertEqual(png.mime, "image/png")
        XCTAssertEqual(png.fileName, "diagram.png")
        XCTAssertEqual(png.md5, "b357a19c87624c7c4d131aeeb4ae677f")
        XCTAssertEqual(png.data.count, 70)
        XCTAssertTrue(png.isImage)

        let pdf = resources[1]
        XCTAssertEqual(pdf.mime, "application/pdf")
        XCTAssertNil(pdf.fileName)
        XCTAssertEqual(pdf.md5, "1bbc324fd49ac1b6e692f4520dcc42d7")
        XCTAssertEqual(pdf.data.count, 69)
        XCTAssertFalse(pdf.isImage)

        // The hash is what <en-media> joins on, so recompute it independently of the parser.
        XCTAssertEqual(MD5.hexDigest(png.data), png.md5)
        XCTAssertEqual(MD5.hexDigest(pdf.data), pdf.md5)
    }

    func testNoteWithNoResourcesHasEmptyIndex() throws {
        let notes = try Fixtures.notes(in: "media")
        XCTAssertTrue(notes[1].resources.isEmpty)
        XCTAssertTrue(notes[1].resourcesByHash().isEmpty)
    }

    func testMimeExtensionFallsBackThroughFilenameThenBin() {
        let known = Resource(data: Data(), mime: "image/jpeg", md5: "x", fileName: nil, sourceURL: nil)
        XCTAssertEqual(known.mimeExtension, "jpg")

        let viaFileName = Resource(
            data: Data(), mime: "application/x-weird", md5: "x", fileName: "notes.pages",
            sourceURL: nil
        )
        XCTAssertEqual(viaFileName.mimeExtension, "pages")

        let unknown = Resource(data: Data(), mime: "", md5: "x", fileName: nil, sourceURL: nil)
        XCTAssertEqual(unknown.mimeExtension, "bin")
    }

    // MARK: MD5

    func testMD5KnownAnswers() {
        XCTAssertEqual(MD5.hexDigest(Data()), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hexDigest(Data("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(
            MD5.hexDigest(Data("The quick brown fox jumps over the lazy dog".utf8)),
            "9e107d9d372bb6826bd81d3542a419d6"
        )
        // Longer than one 64-byte block, and exercises the length-padding path.
        let long = Data(String(repeating: "a", count: 1000).utf8)
        XCTAssertEqual(MD5.hexDigest(long), "cabe45dcc9ae5b66ba86600cca6b8ba8")
    }

    // MARK: Base64 streaming

    func testBase64AccumulatorHandlesChunkAndWhitespaceBoundaries() {
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        let encoded = payload.base64EncodedString()

        var accumulator = Base64Accumulator()
        // Feed in ragged chunks with interleaved whitespace, the way XMLParser delivers text.
        var index = encoded.startIndex
        var size = 1
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: size, limitedBy: encoded.endIndex) ?? encoded.endIndex
            accumulator.append(String(encoded[index..<end]) + "\n  ")
            index = end
            size = size % 7 + 1
        }
        XCTAssertEqual(accumulator.finish(), payload)
    }

    func testBase64AccumulatorReportsBrokenDataAsEmpty() {
        var accumulator = Base64Accumulator()
        accumulator.append("!!!!not base64!!!!")
        XCTAssertEqual(accumulator.finish(), Data())
    }

    // MARK: Entity handling in the envelope

    func testEnvelopePreScanDetectsUndeclaredEntities() throws {
        let directory = try makeTemporaryDirectory(self)

        let clean = directory.appendingPathComponent("clean.enex")
        try Data(Self.envelope(tag: "plain").utf8).write(to: clean)
        XCTAssertFalse(try ENEXParser.requiresEntityNormalization(fileURL: clean))

        let named = directory.appendingPathComponent("named.enex")
        try Data(Self.envelope(tag: "caf&eacute;").utf8).write(to: named)
        XCTAssertTrue(try ENEXParser.requiresEntityNormalization(fileURL: named))

        let bare = directory.appendingPathComponent("bare.enex")
        try Data(Self.envelope(tag: "Tom & Jerry").utf8).write(to: bare)
        XCTAssertTrue(try ENEXParser.requiresEntityNormalization(fileURL: bare))
    }

    /// An export whose envelope uses DTD-declared entities must still parse, because the DTD is
    /// never fetched (no network at runtime).
    func testEnvelopeWithNamedEntitiesStillParses() throws {
        let directory = try makeTemporaryDirectory(self)
        let url = directory.appendingPathComponent("named.enex")
        try Data(Self.envelope(tag: "caf&eacute; &amp; bar").utf8).write(to: url)

        var notes: [Note] = []
        try ENEXParser.parse(fileURL: url) { notes.append($0) }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].tags, ["café & bar"])
    }

    private static func envelope(tag: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <en-export export-date="20240101T000000Z">
          <note>
            <title>Entity test</title>
            <content><![CDATA[<en-note><div>body</div></en-note>]]></content>
            <created>20230101T000000Z</created>
            <tag>\(tag)</tag>
          </note>
        </en-export>
        """
    }

    // MARK: Handler contract

    func testHandlerErrorAbortsParseAndPropagates() throws {
        struct Stop: Error {}
        var seen = 0
        XCTAssertThrowsError(
            try ENEXParser.parse(fileURL: Fixtures.url("hostile")) { _ in
                seen += 1
                if seen == 2 { throw Stop() }
            }
        ) { error in
            XCTAssertTrue(error is Stop)
        }
        XCTAssertEqual(seen, 2, "parsing should stop at the throwing note, not run to completion")
    }
}
