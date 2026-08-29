import Foundation

// MARK: - Renderer inputs and outputs

/// Where a resource ended up on disk, from the renderer's point of view.
/// The renderer never touches the filesystem; `VaultWriter` decides these paths and hands
/// them over already resolved.
struct ResolvedResource: Equatable {
    var relativePath: String
    var displayName: String
    var isImage: Bool
}

struct ResourceIndex {
    var byHash: [String: ResolvedResource]

    init(byHash: [String: ResolvedResource] = [:]) {
        self.byHash = byHash
    }

    func resolve(_ hash: String) -> ResolvedResource? {
        byHash[hash.lowercased()]
    }

    static let empty = ResourceIndex()
}

struct RenderWarning: Equatable {
    enum Kind: String {
        case orphanMedia
        case htmlFallback
        case enmlParseFailure
        case emptyBody
    }

    var kind: Kind
    var detail: String
}

struct RenderResult {
    var markdown: String
    var warnings: [RenderWarning]
    var mediaReferences: Int
    var orphanMediaReferences: Int
    var fallbackBlocks: Int

    var isBodyEmpty: Bool {
        markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Renderer

/// Walks a parsed ENML tree and produces Markdown.
///
/// Pure by construction: tree and resource index in, string and warnings out, no filesystem
/// and no global state. Anything the Markdown mapping cannot express is handed to
/// `HTMLFallback` rather than approximated, so text is never lost to a lossy mapping.
struct MarkdownRenderer {
    var resources: ResourceIndex

    init(resources: ResourceIndex = .empty) {
        self.resources = resources
    }

    func render(_ root: ENMLElement) -> RenderResult {
        let state = RenderState(resources: resources)
        let blocks = state.renderBlocks(root.children, listDepth: 0)
        return RenderResult(
            markdown: blocks.joined(separator: "\n\n"),
            warnings: state.warnings,
            mediaReferences: state.mediaReferences,
            orphanMediaReferences: state.orphanMediaReferences,
            fallbackBlocks: state.fallbackBlocks
        )
    }

    /// Convenience for the note-level path: parse then render, falling back to raw sanitized
    /// HTML when the ENML will not parse at all. A note never comes out of here empty because
    /// its markup was broken.
    func renderENML(_ enml: String) -> RenderResult {
        do {
            let tree = try ENMLDocument.parse(enml)
            return render(tree)
        } catch {
            let block = HTMLFallback.rawBlock(enml, reason: "enml-parse-failure")
            return RenderResult(
                markdown: block,
                warnings: [
                    RenderWarning(kind: .enmlParseFailure, detail: "\(error)"),
                    RenderWarning(kind: .htmlFallback, detail: "enml-parse-failure"),
                ],
                mediaReferences: 0,
                orphanMediaReferences: 0,
                fallbackBlocks: 1
            )
        }
    }
}

// MARK: - Walk state

private final class RenderState {
    let resources: ResourceIndex
    var warnings: [RenderWarning] = []
    var mediaReferences = 0
    var orphanMediaReferences = 0
    var fallbackBlocks = 0

    init(resources: ResourceIndex) {
        self.resources = resources
    }

    /// Elements with a clean block-level Markdown mapping.
    static let blockElements: Set<String> = [
        "en-note", "div", "p", "center", "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "table", "thead", "tbody", "tfoot", "tr", "td", "th",
        "caption", "colgroup", "col", "blockquote", "pre", "hr",
    ]

    /// Elements with a clean inline Markdown (or safe HTML passthrough) mapping.
    static let inlineElements: Set<String> = [
        "span", "font", "b", "strong", "i", "em", "u", "s", "strike", "del", "ins",
        "a", "code", "tt", "kbd", "samp", "var", "sub", "sup", "small", "big",
        "br", "en-media", "en-todo", "img", "abbr", "cite", "q", "mark",
    ]

    static func isKnown(_ name: String) -> Bool {
        blockElements.contains(name) || inlineElements.contains(name)
    }

    private static let indentUnit = "    "

    // MARK: Block level

    /// Renders a run of sibling nodes into top-level Markdown blocks.
    ///
    /// Runs of inline siblings are gathered into a paragraph; a block-level element flushes
    /// whatever inline content preceded it. Empty containers produce no block at all, which is
    /// what collapses Evernote's `<div><br/></div>` spacer runs into a single blank line.
    func renderBlocks(_ nodes: [ENMLNode], listDepth: Int) -> [String] {
        var blocks: [String] = []
        var inlineBuffer: [ENMLNode] = []

        func flushInline() {
            guard !inlineBuffer.isEmpty else { return }
            let rendered = renderInline(inlineBuffer)
            inlineBuffer.removeAll()
            let paragraph = finalizeParagraph(rendered)
            if !paragraph.isEmpty { blocks.append(paragraph) }
        }

        for node in nodes {
            switch node {
            case .text(let text):
                // Whitespace between block elements is layout, not content.
                if inlineBuffer.isEmpty,
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    continue
                }
                inlineBuffer.append(node)

            case .element(let element):
                let name = element.name.lowercased()
                if RenderState.blockElements.contains(name) || !RenderState.isKnown(name) {
                    flushInline()
                    blocks.append(contentsOf: renderBlockElement(element, listDepth: listDepth))
                } else {
                    inlineBuffer.append(node)
                }
            }
        }
        flushInline()
        return blocks
    }

    private func renderBlockElement(_ element: ENMLElement, listDepth: Int) -> [String] {
        let name = element.name.lowercased()

        switch name {
        case "en-note", "center", "div", "p", "td", "th", "caption":
            if isCodeBlock(element) {
                return [codeFence(plainText(element))]
            }
            return renderBlocks(element.children, listDepth: listDepth)

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(name.dropFirst()) ?? 1
            let text = singleLine(renderInline(element.children))
            guard !text.isEmpty else { return [] }
            return ["\(String(repeating: "#", count: level)) \(text)"]

        case "ul":
            return renderList(element, ordered: false, listDepth: listDepth)

        case "ol":
            return renderList(element, ordered: true, listDepth: listDepth)

        case "li":
            // A stray <li> outside any list; render its content rather than dropping it.
            return renderBlocks(element.children, listDepth: listDepth)

        case "table":
            return renderTable(element, listDepth: listDepth)

        case "thead", "tbody", "tfoot", "tr", "colgroup", "col":
            return renderBlocks(element.children, listDepth: listDepth)

        case "blockquote":
            let inner = renderBlocks(element.children, listDepth: listDepth)
            guard !inner.isEmpty else { return [] }
            let quoted = inner.joined(separator: "\n\n")
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
            return [quoted]

        case "pre":
            return [codeFence(plainText(element))]

        case "hr":
            return ["---"]

        default:
            return [fallback(element, reason: "unmapped-element:\(name)")]
        }
    }

    // MARK: Lists

    private func renderList(_ element: ElementAlias, ordered: Bool, listDepth: Int) -> [String] {
        var lines: [String] = []
        var number = Int(element["start"] ?? "") ?? 1

        for child in element.children {
            guard case .element(let item) = child else { continue }
            let name = item.name.lowercased()

            if name == "ul" || name == "ol" {
                // Malformed nesting: a list directly inside a list, with no <li> between.
                let nested = renderList(item, ordered: name == "ol", listDepth: listDepth + 1)
                lines.append(contentsOf: indent(nested.joined(separator: "\n")).components(separatedBy: "\n"))
                continue
            }

            let (marker, contentChildren) = listMarker(for: item, ordered: ordered, number: number)
            if ordered, !isTodoItem(item) { number += 1 }
            lines.append(contentsOf: renderListItem(contentChildren, marker: marker, listDepth: listDepth))
        }

        guard !lines.isEmpty else { return [] }
        return [lines.joined(separator: "\n")]
    }

    /// Decides the item's bullet, consuming a leading `<en-todo>` when there is one.
    ///
    /// Per plan §4 WP-3.2, `<en-todo>` becomes a checkbox only when it leads a list item;
    /// elsewhere it renders as an inline glyph.
    private func listMarker(
        for item: ElementAlias,
        ordered: Bool,
        number: Int
    ) -> (String, [ENMLNode]) {
        var children = item.children
        if let index = firstMeaningfulIndex(children),
            case .element(let candidate) = children[index],
            candidate.name.lowercased() == "en-todo"
        {
            let checked = (candidate["checked"] ?? "false").lowercased() == "true"
            children.remove(at: index)
            return (checked ? "- [x] " : "- [ ] ", children)
        }
        return (ordered ? "\(number). " : "- ", children)
    }

    private func isTodoItem(_ item: ElementAlias) -> Bool {
        guard let index = firstMeaningfulIndex(item.children),
            case .element(let candidate) = item.children[index]
        else { return false }
        return candidate.name.lowercased() == "en-todo"
    }

    private func firstMeaningfulIndex(_ nodes: [ENMLNode]) -> Int? {
        for (index, node) in nodes.enumerated() {
            switch node {
            case .text(let text):
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return index }
            case .element:
                return index
            }
        }
        return nil
    }

    private func renderListItem(
        _ children: [ENMLNode],
        marker: String,
        listDepth: Int
    ) -> [String] {
        var contentNodes: [ENMLNode] = []
        var nestedListBlocks: [String] = []

        for node in children {
            if case .element(let element) = node {
                let name = element.name.lowercased()
                if name == "ul" || name == "ol" {
                    nestedListBlocks.append(
                        contentsOf: renderList(element, ordered: name == "ol", listDepth: listDepth + 1)
                    )
                    continue
                }
            }
            contentNodes.append(node)
        }

        let blocks = renderBlocks(contentNodes, listDepth: listDepth)
        var lines: [String] = []

        if let first = blocks.first {
            let firstLines = first.components(separatedBy: "\n")
            lines.append(marker + (firstLines.first ?? ""))
            lines.append(contentsOf: firstLines.dropFirst().map { RenderState.indentUnit + $0 })
        } else {
            // An empty item still needs its bullet, or the list silently loses a row.
            lines.append(String(marker.reversed().drop(while: { $0 == " " }).reversed()))
        }

        for block in blocks.dropFirst() {
            lines.append("")
            lines.append(contentsOf: indent(block).components(separatedBy: "\n"))
        }

        for nested in nestedListBlocks {
            lines.append(contentsOf: indent(nested).components(separatedBy: "\n"))
        }

        return lines
    }

    private func indent(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.isEmpty ? "" : RenderState.indentUnit + $0 }
            .joined(separator: "\n")
    }

    // MARK: Tables

    private func renderTable(_ element: ElementAlias, listDepth: Int) -> [String] {
        if let reason = tableFallbackReason(element) {
            return [fallback(element, reason: reason)]
        }

        let rows = collectRows(element)
        guard !rows.isEmpty else { return [fallback(element, reason: "empty-table")] }

        let grid = rows.map { row in row.map { cellText($0) } }
        let columns = grid.map(\.count).max() ?? 0
        guard columns > 0 else { return [fallback(element, reason: "empty-table")] }

        func line(_ cells: [String]) -> String {
            var padded = cells
            while padded.count < columns { padded.append("") }
            return "| " + padded.joined(separator: " | ") + " |"
        }

        // GFM requires a header row. ENML tables rarely use <th>, so the first <tr> becomes
        // the header; no text is lost either way, only the header/body distinction is assumed.
        var lines = [line(grid[0])]
        lines.append("| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |")
        for row in grid.dropFirst() { lines.append(line(row)) }
        return [lines.joined(separator: "\n")]
    }

    /// Why this table cannot be a GFM table, or nil when it can.
    private func tableFallbackReason(_ element: ElementAlias) -> String? {
        var reason: String?

        func walk(_ node: ENMLNode, insideCell: Bool) {
            guard reason == nil, case .element(let current) = node else { return }
            let name = current.name.lowercased()

            if name == "table", insideCell {
                reason = "nested-table"
                return
            }
            if name == "td" || name == "th" {
                for attribute in ["colspan", "rowspan"] {
                    if let raw = current[attribute], raw.trimmingCharacters(in: .whitespaces) != "1",
                        !raw.trimmingCharacters(in: .whitespaces).isEmpty
                    {
                        reason = "merged-cells"
                        return
                    }
                }
                for child in current.children { walk(child, insideCell: true) }
                return
            }
            if insideCell,
                ["ul", "ol", "pre", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name)
            {
                reason = "block-content-in-cell"
                return
            }
            for child in current.children { walk(child, insideCell: insideCell) }
        }

        for child in element.children { walk(child, insideCell: false) }
        return reason
    }

    private func collectRows(_ element: ElementAlias) -> [[ElementAlias]] {
        var rows: [[ElementAlias]] = []

        func walk(_ current: ElementAlias) {
            for child in current.children {
                guard case .element(let node) = child else { continue }
                switch node.name.lowercased() {
                case "tr":
                    let cells = node.children.compactMap { cell -> ElementAlias? in
                        guard case .element(let element) = cell else { return nil }
                        let name = element.name.lowercased()
                        return (name == "td" || name == "th") ? element : nil
                    }
                    rows.append(cells)
                case "thead", "tbody", "tfoot":
                    walk(node)
                default:
                    break
                }
            }
        }

        walk(element)
        return rows
    }

    private func cellText(_ cell: ElementAlias) -> String {
        let blocks = renderBlocks(cell.children, listDepth: 0)
        return
            blocks
            .joined(separator: "\n")
            .replacingOccurrences(of: "\\\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Inline level

    func renderInline(_ nodes: [ENMLNode]) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .text(let text):
                out += escapeInline(text)
            case .element(let element):
                out += renderInlineElement(element)
            }
        }
        return out
    }

    private func renderInlineElement(_ element: ElementAlias) -> String {
        let name = element.name.lowercased()

        switch name {
        case "b", "strong":
            return emphasize(element.children, marker: "**")
        case "i", "em":
            return emphasize(element.children, marker: "*")
        case "s", "strike", "del":
            return emphasize(element.children, marker: "~~")
        case "u", "ins":
            return htmlWrap(name == "ins" ? "ins" : "u", element.children)
        case "sub", "sup", "small", "big", "mark", "abbr", "cite", "q":
            return htmlWrap(name, element.children)
        case "code", "tt", "kbd", "samp", "var":
            return codeSpan(plainText(element))
        case "br":
            return "\n"
        case "a":
            return link(element)
        case "img":
            return image(element)
        case "en-media":
            return media(element)
        case "en-todo":
            let checked = (element["checked"] ?? "false").lowercased() == "true"
            return checked ? "\u{2611}" : "\u{2610}"
        case "span", "font":
            return styled(element)
        default:
            if RenderState.blockElements.contains(name) {
                // A block element in inline position: keep its text rather than restructuring.
                let inner = renderInline(element.children)
                return inner.isEmpty ? "" : "\n\(inner)\n"
            }
            return inlineFallback(element, reason: "unmapped-element:\(name)")
        }
    }

    private func emphasize(_ children: [ENMLNode], marker: String) -> String {
        let inner = renderInline(children)
        guard !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return inner }
        // Emphasis delimiters cannot sit next to whitespace in CommonMark; push it outside.
        let leading = String(inner.prefix(while: { $0 == " " || $0 == "\t" }))
        let trailing = String(inner.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
        let core = String(inner.dropFirst(leading.count).dropLast(trailing.count))
        return "\(leading)\(marker)\(core)\(marker)\(trailing)"
    }

    private func htmlWrap(_ tag: String, _ children: [ENMLNode]) -> String {
        let inner = renderInline(children)
        guard !inner.isEmpty else { return "" }
        return "<\(tag)>\(inner)</\(tag)>"
    }

    private func codeSpan(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var fence = "`"
        while text.contains(fence) { fence += "`" }
        let pad = (text.hasPrefix("`") || text.hasSuffix("`")) ? " " : ""
        return "\(fence)\(pad)\(text)\(pad)\(fence)"
    }

    private func styled(_ element: ElementAlias) -> String {
        let style = (element["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        var markers: [String] = []
        if style.contains("font-weight:bold") || style.contains("font-weight:700")
            || style.contains("font-weight:800") || style.contains("font-weight:900")
        {
            markers.append("**")
        }
        if style.contains("font-style:italic") { markers.append("*") }

        let decoration = style.contains("text-decoration")
        var inner = renderInline(element.children)
        if decoration, style.contains("line-through") {
            inner = wrapCore(inner, marker: "~~")
        }
        if decoration, style.contains("underline") {
            inner = inner.isEmpty ? inner : "<u>\(inner)</u>"
        }
        for marker in markers.reversed() {
            inner = wrapCore(inner, marker: marker)
        }
        return inner
    }

    private func wrapCore(_ text: String, marker: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        let leading = String(text.prefix(while: { $0 == " " || $0 == "\t" }))
        let trailing = String(text.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
        let core = String(text.dropFirst(leading.count).dropLast(trailing.count))
        return "\(leading)\(marker)\(core)\(marker)\(trailing)"
    }

    private func link(_ element: ElementAlias) -> String {
        let href = (element["href"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let label = renderInline(element.children)
        guard !href.isEmpty else { return label }
        if HTMLFallback.isDangerousURL(href) {
            // Keep the text, drop the executable destination.
            return label.isEmpty ? escapeInline(href) : label
        }
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? escapeInline(href) : label
        return "[\(singleLine(text))](\(destination(href)))"
    }

    private func image(_ element: ElementAlias) -> String {
        let source = (element["src"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let alt = escapeInline(element["alt"] ?? "")
        guard !source.isEmpty, !HTMLFallback.isDangerousURL(source) else { return alt }
        return "![\(alt)](\(destination(source)))"
    }

    private func media(_ element: ElementAlias) -> String {
        mediaReferences += 1
        let hash = (element["hash"] ?? "").lowercased()
        guard let resolved = resources.resolve(hash) else {
            orphanMediaReferences += 1
            let mime = element["type"] ?? ""
            warnings.append(
                RenderWarning(
                    kind: .orphanMedia,
                    detail: "en-media hash=\(hash.isEmpty ? "<missing>" : hash) type=\(mime)"
                )
            )
            return
                "\(orphanMediaMarkerPrefix) hash=\"\(HTMLFallback.escapeAttribute(hash))\" mime=\"\(HTMLFallback.escapeAttribute(mime))\" -->"
        }
        let label = escapeInline(resolved.displayName)
        let target = destination(resolved.relativePath)
        return resolved.isImage ? "![\(label)](\(target))" : "[\(label)](\(target))"
    }

    /// Wraps a link destination in angle brackets when it contains characters that would
    /// terminate the inline-link syntax early.
    private func destination(_ raw: String) -> String {
        let needsBrackets = raw.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" })
        guard needsBrackets else { return raw }
        let escaped =
            raw
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
        return "<\(escaped)>"
    }

    // MARK: Fallbacks

    private func fallback(_ element: ElementAlias, reason: String) -> String {
        fallbackBlocks += 1
        warnings.append(RenderWarning(kind: .htmlFallback, detail: reason))
        return HTMLFallback.block(for: element, reason: reason, resources: resources)
    }

    /// Same accounting as `fallback`, but emitted mid-paragraph where a block cannot go.
    private func inlineFallback(_ element: ElementAlias, reason: String) -> String {
        fallbackBlocks += 1
        warnings.append(RenderWarning(kind: .htmlFallback, detail: reason))
        let html = HTMLFallback.collapseBlankLines(
            HTMLFallback.serialize(.element(element), resources: resources)
        )
        return "\(htmlFallbackMarkerPrefix) reason=\"\(HTMLFallback.escapeAttribute(reason))\" -->\(html)"
    }

    // MARK: Text helpers

    /// Raw text with `<br/>` as newlines and no Markdown escaping — for code blocks and spans,
    /// where escaping would corrupt the content.
    private func plainText(_ element: ElementAlias) -> String {
        var out = ""
        for child in element.children {
            switch child {
            case .text(let text):
                out += text
            case .element(let inner):
                let name = inner.name.lowercased()
                if name == "br" {
                    out += "\n"
                } else if RenderState.blockElements.contains(name) {
                    let nested = plainText(inner)
                    if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
                    out += nested
                    out += "\n"
                } else {
                    out += plainText(inner)
                }
            }
        }
        return out
    }

    private func isCodeBlock(_ element: ElementAlias) -> Bool {
        guard let style = element["style"] else { return false }
        return style.replacingOccurrences(of: " ", with: "").lowercased().contains("en-codeblock:true")
    }

    private func codeFence(_ code: String) -> String {
        var body = code
        while body.hasSuffix("\n") { body.removeLast() }
        var fence = "```"
        while body.contains(fence) { fence += "`" }
        return "\(fence)\n\(body)\n\(fence)"
    }

    private func singleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Turns accumulated inline text into a paragraph block: trailing whitespace trimmed,
    /// `<br/>` runs collapsed to one hard break, and line-leading Markdown syntax escaped.
    private func finalizeParagraph(_ text: String) -> String {
        let lines =
            text
            .components(separatedBy: "\n")
            .map { line -> String in
                String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
            }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }
        // A backslash at end of line is CommonMark's unambiguous hard break; trailing spaces
        // would be stripped by editors and git.
        return lines.map(escapeLineStart).joined(separator: "\\\n")
    }

    /// Escapes Markdown block syntax that only has meaning at the start of a line.
    private func escapeLineStart(_ line: String) -> String {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 3 {
            index = line.index(after: index)
            leadingSpaces += 1
        }
        guard index < line.endIndex else { return line }
        let rest = line[index...]

        func escaped() -> String {
            String(line[line.startIndex..<index]) + "\\" + rest
        }

        let first = rest[rest.startIndex]
        if first == ">" || first == "=" { return escaped() }
        if first == "-" || first == "+" {
            let after = rest.index(after: rest.startIndex)
            if after == rest.endIndex || rest[after] == " " || rest[after] == first { return escaped() }
        }
        if first == "#" {
            let hashes = rest.prefix(while: { $0 == "#" })
            let after = rest.index(rest.startIndex, offsetBy: hashes.count)
            if hashes.count <= 6, after == rest.endIndex || rest[after] == " " { return escaped() }
        }
        if first.isNumber {
            let digits = rest.prefix(while: { $0.isNumber })
            if digits.count <= 9 {
                let after = rest.index(rest.startIndex, offsetBy: digits.count)
                if after < rest.endIndex, rest[after] == "." || rest[after] == ")" {
                    let following = rest.index(after: after)
                    if following == rest.endIndex || rest[following] == " " {
                        return String(line[line.startIndex..<index]) + digits + "\\"
                            + String(rest[after...])
                    }
                }
            }
        }
        return line
    }

    /// Escapes the inline Markdown metacharacters. Deliberately narrow: `_` is only escaped at
    /// word boundaries and `~` only when doubled, so ordinary prose and snake_case identifiers
    /// do not acquire backslashes they do not need.
    func escapeInline(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let characters = Array(text)
        var out = ""
        out.reserveCapacity(text.count)

        for (index, character) in characters.enumerated() {
            switch character {
            case "\\", "`", "*", "[", "]", "<":
                out.append("\\")
                out.append(character)
            case "_":
                let previousIsWord =
                    index > 0 && (characters[index - 1].isLetter || characters[index - 1].isNumber)
                let nextIsWord =
                    index + 1 < characters.count
                    && (characters[index + 1].isLetter || characters[index + 1].isNumber)
                if previousIsWord && nextIsWord {
                    out.append(character)
                } else {
                    out.append("\\_")
                }
            case "~":
                let adjacentTilde =
                    (index + 1 < characters.count && characters[index + 1] == "~")
                    || (index > 0 && characters[index - 1] == "~")
                out.append(adjacentTilde ? "\\~" : "~")
            case "&":
                out.append(looksLikeEntity(characters, from: index) ? "\\&" : "&")
            default:
                out.append(character)
            }
        }
        return out
    }

    /// True when `&` at `index` begins something a Markdown renderer would decode as an
    /// entity, in which case the literal ampersand needs escaping to survive.
    private func looksLikeEntity(_ characters: [Character], from index: Int) -> Bool {
        var cursor = index + 1
        if cursor < characters.count, characters[cursor] == "#" { cursor += 1 }
        var length = 0
        while cursor < characters.count, characters[cursor].isLetter || characters[cursor].isNumber {
            cursor += 1
            length += 1
            if length > 32 { return false }
        }
        return length > 0 && cursor < characters.count && characters[cursor] == ";"
    }
}

/// Local alias kept for readability in the walk above, where `ENMLElement` appears constantly.
private typealias ElementAlias = ENMLElement
