import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

// MARK: - Tree

/// A node in a parsed ENML document. Text nodes carry their content verbatim; nothing is
/// trimmed or collapsed here, because the renderer needs to decide what whitespace means.
enum ENMLNode {
    case text(String)
    case element(ENMLElement)
}

struct ENMLElement {
    var name: String
    /// XMLParser hands attributes back as a dictionary, so source order is already lost.
    /// Emitters sort by name to stay deterministic.
    var attributes: [String: String]
    var children: [ENMLNode]

    subscript(attribute: String) -> String? {
        attributes[attribute]
    }

    /// All text beneath this element, concatenated. Used by the losslessness tests and by
    /// the code-block and table paths.
    var textContent: String {
        var result = ""
        for child in children {
            switch child {
            case .text(let text): result += text
            case .element(let element): result += element.textContent
            }
        }
        return result
    }
}

// MARK: - Parsing

struct ENMLParseError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

enum ENMLDocument {

    /// Parses the ENML from a note's `<content>` into a tree rooted at `en-note`.
    ///
    /// Three passes, escalating only on failure:
    /// 1. strict — normalized entities, DOCTYPE stripped;
    /// 2. repaired — additionally self-closes unclosed void elements (`<br>`);
    /// 3. throw, leaving the caller to fall back to raw HTML so the note keeps its content.
    static func parse(_ enml: String) throws -> ENMLElement {
        let prepared = prepare(enml)
        if let tree = try? parseStrict(prepared) {
            return tree
        }
        let repaired = closeVoidElements(prepared)
        do {
            return try parseStrict(repaired)
        } catch {
            throw ENMLParseError(message: "ENML is not well-formed XML: \(error)")
        }
    }

    /// Entity normalization, DOCTYPE removal, and BOM/whitespace trimming.
    ///
    /// Note: Foundation's XMLParser (libxml2) silently drops U+FEFF from character data wherever
    /// it appears, not just at the start. It is ZERO WIDTH NO-BREAK SPACE, so nothing visible is
    /// lost, but a stray one copied into a note will not survive into the Markdown.
    static func prepare(_ enml: String) -> String {
        var text = enml
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripDoctype(text)
        text = ENMLEntities.normalize(text)
        return text
    }

    private static func parseStrict(_ text: String) throws -> ENMLElement {
        let builder = ENMLTreeBuilder()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false

        // Notes are rendered from inside the ENEX parser's delegate callback, and NSXMLParser
        // refuses to start a parse while one is already running on the same thread. See
        // ENMLParseWorker.
        var succeeded = false
        ENMLParseWorker.shared.run { succeeded = parser.parse() }

        guard succeeded, let root = builder.root else {
            throw ENMLParseError(
                message: parser.parserError?.localizedDescription
                    ?? "malformed ENML at line \(parser.lineNumber)"
            )
        }
        return root
    }

    /// Removes `<!DOCTYPE ...>`. ENML's doctype has no internal subset, so a flat scan to the
    /// matching `>` is sufficient and avoids pulling in a regex for the common path.
    static func stripDoctype(_ text: String) -> String {
        guard let start = text.range(of: "<!DOCTYPE", options: [.caseInsensitive]) else {
            return text
        }
        guard let end = text.range(of: ">", range: start.upperBound..<text.endIndex) else {
            return text
        }
        var result = text
        result.removeSubrange(start.lowerBound..<end.upperBound)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HTML void elements written unclosed (`<br>`) are common in hand-edited or third-party
    /// ENEX. Applied only after a strict parse has already failed.
    static func closeVoidElements(_ text: String) -> String {
        let names = "br|hr|img|en-media|en-todo|input|meta|link|col|area|base|embed|param|source|track|wbr"
        guard
            let regex = try? NSRegularExpression(
                pattern: "<(\(names))\\b([^<>]*?)/?>",
                options: [.caseInsensitive]
            )
        else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "<$1$2/>"
        )
    }
}

private final class ENMLTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: ENMLElement?
    private var stack: [ENMLElement] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        stack.append(ENMLElement(name: elementName, attributes: attributes, children: []))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].children.append(.text(string))
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].children.append(.text(text))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard let finished = stack.popLast() else { return }
        if stack.isEmpty {
            root = finished
        } else {
            stack[stack.count - 1].children.append(.element(finished))
        }
    }
}


// MARK: - Reentrancy

/// Runs ENML parses off whichever thread is currently running an ENEX parse.
///
/// NSXMLParser raises `NSInternalInconsistencyException` ("does not support reentrant parsing")
/// when a parse begins inside another parse's delegate callback — which is exactly what
/// streaming ENEX notes into the renderer does. The guard is per-thread, so one dedicated
/// worker thread, which never nests a parse of its own, is sufficient. It is long-lived so that
/// a 20k-note export does not create 20k threads.
///
/// The alternative fixes are worse: buffering every note until the ENEX parse finishes would
/// give up the streaming memory profile WP-2 requires, and hand-writing an ENML tokenizer is a
/// larger change than this defect warrants without a decision from the planner.
final class ENMLParseWorker: @unchecked Sendable {
    static let shared = ENMLParseWorker()

    private let lock = NSLock()
    private let jobReady = DispatchSemaphore(value: 0)
    private let jobFinished = DispatchSemaphore(value: 0)
    private var job: (() -> Void)?
    private var workerThread: Thread?

    private init() {
        let thread = Thread { [self] in
            while true {
                jobReady.wait()
                job?()
                job = nil
                jobFinished.signal()
            }
        }
        thread.name = "enexodus.enml-parse"
        // The tree builder recurses with document depth; 4 MiB leaves plenty of headroom.
        thread.stackSize = 4 << 20
        workerThread = thread
        thread.start()
    }

    /// Runs `work` on the worker thread and blocks until it returns.
    func run(_ work: () -> Void) {
        // Defensive: an ENML parse never nests inside another, but if it ever did, handing the
        // job to the thread already waiting on it would deadlock.
        if Thread.current === workerThread {
            work()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        withoutActuallyEscaping(work) { escaping in
            job = escaping
            jobReady.signal()
            jobFinished.wait()
        }
    }
}

// MARK: - Entities

/// ENML declares its named entities in an external DTD that must never be fetched (no network
/// at runtime, plan §5). XMLParser therefore rejects `&nbsp;` outright. Rewriting named
/// entities to numeric references before parsing keeps the text and keeps the parser offline.
enum ENMLEntities {

    /// Rewrites named character references to numeric ones and escapes any `&` that does not
    /// begin a valid reference. The five XML built-ins are left alone.
    static func normalize(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            guard character == "&" else {
                result.append(character)
                index = text.index(after: index)
                continue
            }

            // Look ahead for `name;`, `#123;` or `#xAB;` within a plausible window.
            var cursor = text.index(after: index)
            var body = ""
            var terminated = false
            while cursor < text.endIndex, body.count <= 32 {
                let next = text[cursor]
                if next == ";" {
                    terminated = true
                    break
                }
                if next.isLetter || next.isNumber || next == "#" {
                    body.append(next)
                    cursor = text.index(after: cursor)
                } else {
                    break
                }
            }

            if terminated, !body.isEmpty {
                if body.hasPrefix("#") {
                    // Numeric references are already parseable.
                    result += "&\(body);"
                } else if xmlBuiltins.contains(body) {
                    result += "&\(body);"
                } else if let scalar = named[body] {
                    result += "&#\(scalar);"
                } else {
                    // Unknown name: keep the literal text rather than dropping it.
                    result += "&amp;\(body);"
                }
                index = text.index(after: cursor)
            } else {
                // A bare ampersand.
                result += "&amp;"
                index = text.index(after: index)
            }
        }
        return result
    }

    static let xmlBuiltins: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /// HTML4 named entities plus the HTML5 names Evernote's editor emits.
    static let named: [String: UInt32] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165,
        "brvbar": 166, "sect": 167, "uml": 168, "copy": 169, "ordf": 170, "laquo": 171,
        "not": 172, "shy": 173, "reg": 174, "macr": 175, "deg": 176, "plusmn": 177,
        "sup2": 178, "sup3": 179, "acute": 180, "micro": 181, "para": 182, "middot": 183,
        "cedil": 184, "sup1": 185, "ordm": 186, "raquo": 187, "frac14": 188, "frac12": 189,
        "frac34": 190, "iquest": 191, "Agrave": 192, "Aacute": 193, "Acirc": 194,
        "Atilde": 195, "Auml": 196, "Aring": 197, "AElig": 198, "Ccedil": 199,
        "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203, "Igrave": 204,
        "Iacute": 205, "Icirc": 206, "Iuml": 207, "ETH": 208, "Ntilde": 209,
        "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213, "Ouml": 214,
        "times": 215, "Oslash": 216, "Ugrave": 217, "Uacute": 218, "Ucirc": 219,
        "Uuml": 220, "Yacute": 221, "THORN": 222, "szlig": 223, "agrave": 224,
        "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229,
        "aelig": 230, "ccedil": 231, "egrave": 232, "eacute": 233, "ecirc": 234,
        "euml": 235, "igrave": 236, "iacute": 237, "icirc": 238, "iuml": 239,
        "eth": 240, "ntilde": 241, "ograve": 242, "oacute": 243, "ocirc": 244,
        "otilde": 245, "ouml": 246, "divide": 247, "oslash": 248, "ugrave": 249,
        "uacute": 250, "ucirc": 251, "uuml": 252, "yacute": 253, "thorn": 254,
        "yuml": 255,
        "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353, "Yuml": 376,
        "fnof": 402, "circ": 710, "tilde": 732,
        "Alpha": 913, "Beta": 914, "Gamma": 915, "Delta": 916, "Epsilon": 917,
        "Zeta": 918, "Eta": 919, "Theta": 920, "Iota": 921, "Kappa": 922,
        "Lambda": 923, "Mu": 924, "Nu": 925, "Xi": 926, "Omicron": 927, "Pi": 928,
        "Rho": 929, "Sigma": 931, "Tau": 932, "Upsilon": 933, "Phi": 934, "Chi": 935,
        "Psi": 936, "Omega": 937,
        "alpha": 945, "beta": 946, "gamma": 947, "delta": 948, "epsilon": 949,
        "zeta": 950, "eta": 951, "theta": 952, "iota": 953, "kappa": 954,
        "lambda": 955, "mu": 956, "nu": 957, "xi": 958, "omicron": 959, "pi": 960,
        "rho": 961, "sigmaf": 962, "sigma": 963, "tau": 964, "upsilon": 965,
        "phi": 966, "chi": 967, "psi": 968, "omega": 969, "thetasym": 977,
        "upsih": 978, "piv": 982,
        "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205,
        "lrm": 8206, "rlm": 8207, "ndash": 8211, "mdash": 8212, "lsquo": 8216,
        "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222,
        "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240,
        "prime": 8242, "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "oline": 8254,
        "frasl": 8260, "euro": 8364,
        "image": 8465, "weierp": 8472, "real": 8476, "trade": 8482, "alefsym": 8501,
        "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595, "harr": 8596,
        "crarr": 8629, "lArr": 8656, "uArr": 8657, "rArr": 8658, "dArr": 8659,
        "hArr": 8660,
        "forall": 8704, "part": 8706, "exist": 8707, "empty": 8709, "nabla": 8711,
        "isin": 8712, "notin": 8713, "ni": 8715, "prod": 8719, "sum": 8721,
        "minus": 8722, "lowast": 8727, "radic": 8730, "prop": 8733, "infin": 8734,
        "ang": 8736, "and": 8743, "or": 8744, "cap": 8745, "cup": 8746, "int": 8747,
        "there4": 8756, "sim": 8764, "cong": 8773, "asymp": 8776, "ne": 8800,
        "equiv": 8801, "le": 8804, "ge": 8805, "sub": 8834, "sup": 8835, "nsub": 8836,
        "sube": 8838, "supe": 8839, "oplus": 8853, "otimes": 8855, "perp": 8869,
        "sdot": 8901, "lceil": 8968, "rceil": 8969, "lfloor": 8970, "rfloor": 8971,
        "lang": 9001, "rang": 9002, "loz": 9674,
        "spades": 9824, "clubs": 9827, "hearts": 9829, "diams": 9830,
        // HTML5 additions seen in Evernote content.
        "apos2": 39, "copysr": 8471, "starf": 9733, "star": 9734, "phone": 9742,
        "female": 9792, "male": 9794, "check": 10003, "cross": 10007,
    ]
}
