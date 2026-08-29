import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

struct ENEXParseError: Error, CustomStringConvertible {
    var file: String
    var message: String
    var line: Int?

    var description: String {
        if let line {
            return "\(file):\(line): \(message)"
        }
        return "\(file): \(message)"
    }
}

/// Streaming ENEX reader.
///
/// Notes are handed to the caller one at a time and dropped immediately afterwards, so peak
/// memory is bounded by the largest single note (its ENML plus its decoded resources) rather
/// than by the file. A multi-hundred-MB export with ordinary notes stays flat.
final class ENEXParser: NSObject, XMLParserDelegate {

    /// Called once per `</note>`. Throwing aborts the parse and the error is rethrown.
    typealias NoteHandler = (Note) throws -> Void

    // MARK: - Entry points

    /// Parses `fileURL`, streaming from disk.
    ///
    /// The envelope's DTD is never fetched, so an export carrying HTML named entities
    /// (`&nbsp;`) or a bare `&` in a title would fail to parse. A cheap streaming pre-scan
    /// decides that up front rather than discovering it mid-parse: retrying afterwards would
    /// hand `onNote` the leading notes a second time.
    ///
    /// The normalized path holds the file in memory, so it is taken only when needed. Evernote's
    /// own exporter escapes numerically and stays on the streaming path.
    @discardableResult
    static func parse(fileURL: URL, onNote: NoteHandler) throws -> Int {
        let name = fileURL.lastPathComponent

        if try requiresEntityNormalization(fileURL: fileURL) {
            let raw = try String(contentsOf: fileURL, encoding: .utf8)
            let data = Data(ENMLEntities.normalize(raw).utf8)
            return try drive(fileName: name, onNote: onNote, repaired: true) {
                XMLParser(data: data)
            }
        }

        guard let stream = InputStream(url: fileURL) else {
            throw ENEXParseError(file: name, message: "cannot open file")
        }
        return try drive(fileName: name, onNote: onNote) { XMLParser(stream: stream) }
    }

    /// The parse is synchronous and the delegate does not outlive it, so the handler never
    /// actually escapes — this keeps callers from having to hold their closures alive.
    private static func drive(
        fileName: String,
        onNote: NoteHandler,
        repaired: Bool = false,
        makeParser: () -> XMLParser
    ) throws -> Int {
        try withoutActuallyEscaping(onNote) { escaping in
            let delegate = ENEXParser(fileName: fileName, onNote: escaping)
            delegate.repairedEntities = repaired
            return try delegate.run(makeParser())
        }
    }

    /// True when the envelope contains an `&` that libxml2 would reject: a named entity the
    /// (unfetched) DTD would have declared, or an unescaped bare ampersand.
    ///
    /// Reads in 1 MiB chunks with a 64-byte overlap so a reference straddling a chunk boundary
    /// is still seen whole. Memory stays flat regardless of file size.
    static func requiresEntityNormalization(fileURL: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let overlap = 64
        var carry: [UInt8] = []

        while true {
            // Each `read` hands back an autoreleased NSData. Without a pool drained per
            // iteration those accumulate for the whole file, which made peak RSS track file
            // size exactly (290 MB file -> 290 MB resident) and defeated the streaming design.
            var chunk = Data()
            autoreleasepool {
                chunk = (try? handle.read(upToCount: 1 << 20)) .flatMap { $0 } ?? Data()
            }
            let isLast = chunk.isEmpty
            var bytes = carry
            bytes.append(contentsOf: chunk)
            if bytes.isEmpty { return false }

            let limit = isLast ? bytes.count : max(0, bytes.count - overlap)
            var index = 0
            while index < limit {
                guard bytes[index] == UInt8(ascii: "&") else {
                    index += 1
                    continue
                }
                var cursor = index + 1
                var name = ""
                while cursor < bytes.count, cursor - index <= 33 {
                    let byte = bytes[cursor]
                    if byte == UInt8(ascii: ";") { break }
                    let isNameByte =
                        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                        || (byte >= 0x61 && byte <= 0x7A) || byte == UInt8(ascii: "#")
                    guard isNameByte else { break }
                    name.append(Character(UnicodeScalar(byte)))
                    cursor += 1
                }
                let terminated = cursor < bytes.count && bytes[cursor] == UInt8(ascii: ";")
                if terminated, !name.isEmpty,
                    name.hasPrefix("#") || ENMLEntities.xmlBuiltins.contains(name)
                {
                    index = cursor + 1
                    continue
                }
                return true
            }

            if isLast { return false }
            carry = Array(bytes.suffix(overlap))
        }
    }

    /// In-memory variant, used by the tests and by the entity-repair retry above.
    @discardableResult
    static func parse(string: String, fileName: String = "<memory>", onNote: NoteHandler) throws -> Int {
        let data = Data(string.utf8)
        return try drive(fileName: fileName, onNote: onNote) { XMLParser(data: data) }
    }

    // MARK: - State

    private let fileName: String
    private let onNote: NoteHandler

    private var elementStack: [String] = []
    private var textBuffer = ""
    private var noteCount = 0

    private var note: Note?
    private var resource: PartialResource?
    private var resourceData = Base64Accumulator()
    private var isCapturingResourceData = false

    private var handlerError: Error?
    private var parseError: Error?
    /// Set when libxml2 reports an undefined entity, which is the signal to retry normalized.
    private(set) var sawUndefinedEntity = false
    private(set) var repairedEntities = false

    private let dateFormatter = ENEXDate.makeFormatter()

    private init(fileName: String, onNote: @escaping NoteHandler) {
        self.fileName = fileName
        self.onNote = onNote
    }

    private func run(_ parser: XMLParser) throws -> Int {
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()
        if let handlerError { throw handlerError }
        if !ok {
            if let parseError { throw parseError }
            let underlying = parser.parserError
            throw ENEXParseError(
                file: fileName,
                message: underlying?.localizedDescription ?? "XML parse failed",
                line: parser.lineNumber
            )
        }
        return noteCount
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        elementStack.append(elementName)
        textBuffer = ""

        switch elementName {
        case "note":
            note = Note(
                title: "",
                content: "",
                created: nil,
                updated: nil,
                tags: [],
                attributes: [:],
                resources: []
            )
        case "resource":
            resource = PartialResource()
            resourceData = Base64Accumulator()
        case "data":
            if elementStack.contains("resource") {
                isCapturingResourceData = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCapturingResourceData {
            resourceData.append(string)
        } else {
            textBuffer += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else {
            // A CDATA block that is not UTF-8 would silently vanish; refuse instead.
            fail("non-UTF-8 CDATA in <\(elementStack.last ?? "?")>", parser: parser)
            return
        }
        if isCapturingResourceData {
            resourceData.append(text)
        } else {
            textBuffer += text
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        defer {
            if !elementStack.isEmpty { elementStack.removeLast() }
            textBuffer = ""
        }

        let inResource = elementStack.dropLast().contains("resource")
        let inNoteAttributes = elementStack.dropLast().last == "note-attributes"
        let inResourceAttributes = elementStack.dropLast().last == "resource-attributes"
        let text = textBuffer

        switch elementName {
        case "note":
            guard let finished = note else { break }
            note = nil
            noteCount += 1
            // A note's rendering and writing churn through Foundation objects; draining per
            // note keeps peak memory bounded by the largest single note rather than the file.
            var thrown: Error?
            autoreleasepool {
                do {
                    try onNote(finished)
                } catch {
                    thrown = error
                }
            }
            if let thrown {
                handlerError = thrown
                parser.abortParsing()
            }

        case "resource":
            guard var partial = resource else { break }
            partial.data = resourceData.finish()
            resource = nil
            resourceData = Base64Accumulator()
            note?.resources.append(partial.materialize())

        case "data":
            isCapturingResourceData = false

        case "title" where !inResource:
            note?.title = text

        case "content":
            note?.content = text

        case "created":
            note?.created = dateFormatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))

        case "updated":
            note?.updated = dateFormatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))

        case "tag":
            let tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty, note?.tags.contains(tag) == false {
                note?.tags.append(tag)
            }

        case "mime" where inResource:
            resource?.mime = text.trimmingCharacters(in: .whitespacesAndNewlines)

        case "file-name" where inResourceAttributes:
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { resource?.fileName = name }

        case "source-url" where inResourceAttributes:
            let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty { resource?.sourceURL = url }

        default:
            // Everything under <note-attributes> is passed through verbatim so the writer can
            // decide what to surface, rather than the parser deciding for it.
            if inNoteAttributes {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { note?.attributes[elementName] = value }
            }
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        let message = error.localizedDescription
        if message.lowercased().contains("entity") {
            sawUndefinedEntity = true
        }
        if parseError == nil {
            parseError = ENEXParseError(file: fileName, message: message, line: parser.lineNumber)
        }
    }

    private func fail(_ message: String, parser: XMLParser) {
        if parseError == nil {
            parseError = ENEXParseError(file: fileName, message: message, line: parser.lineNumber)
        }
        parser.abortParsing()
    }
}

// MARK: - Supporting types

/// A `<resource>` under construction. Kept separate from `Resource` so the MD5 is computed
/// exactly once, at the point the bytes are complete.
private struct PartialResource {
    var data = Data()
    var mime = ""
    var fileName: String?
    var sourceURL: String?

    func materialize() -> Resource {
        Resource(
            data: data,
            mime: mime,
            md5: MD5.hexDigest(data),
            fileName: fileName,
            sourceURL: sourceURL
        )
    }
}

/// Incremental base64 decoder.
///
/// XMLParser delivers `<data>` in small chunks. Buffering the whole base64 text before decoding
/// would hold ~1.33x the resource size in addition to the decoded bytes; flushing on 4-char
/// boundaries keeps the encoded side bounded by `flushThreshold` instead.
struct Base64Accumulator {
    private var pending: [UInt8] = []
    private var decoded = Data()
    private var isBroken = false

    /// Multiple of 4 so that no group is ever split across a flush.
    private let flushThreshold = 64 * 1024

    mutating func append(_ chunk: String) {
        for byte in chunk.utf8 {
            switch byte {
            case 0x20, 0x09, 0x0a, 0x0d:
                continue
            default:
                pending.append(byte)
            }
        }
        while pending.count >= flushThreshold {
            let group = Array(pending.prefix(flushThreshold))
            pending.removeFirst(flushThreshold)
            decode(group)
        }
    }

    mutating func finish() -> Data {
        if !pending.isEmpty {
            let group = pending
            pending.removeAll()
            decode(group)
        }
        let result = decoded
        decoded = Data()
        return isBroken ? Data() : result
    }

    private mutating func decode(_ bytes: [UInt8]) {
        guard !isBroken else { return }
        let text = String(decoding: bytes, as: UTF8.self)
        guard let chunk = Data(base64Encoded: text, options: []) else {
            isBroken = true
            decoded = Data()
            return
        }
        decoded.append(chunk)
    }
}
