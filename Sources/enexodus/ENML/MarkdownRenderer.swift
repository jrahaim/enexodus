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
    var spacing: Spacing

    /// How to treat Evernote's `<div><br/></div>` spacer lines.
    enum Spacing: String, CaseIterable, Sendable {
        /// Reproduce every spacer as a blank line — what the note looked like in Evernote.
        case faithful
        /// Drop spacers in notes that use one after *every* line.
        ///
        /// A separator that appears everywhere separates nothing: it is a typing habit, not
        /// structure. Notes that use spacers only at some boundaries are left alone, because
        /// there the blank lines really are breaking up thoughts.
        case tight
    }

    init(resources: ResourceIndex = .empty, spacing: Spacing = .faithful) {
        self.resources = resources
        self.spacing = spacing
    }

    func render(_ root: ENMLElement) -> RenderResult {
        let state = RenderState(resources: resources)
        let blocks = state.renderDocument(root.children, spacing: spacing)
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

    /// One piece of rendered output, before blocks are assembled.
    ///
    /// The distinction that matters is `line` vs `paragraphBreak`. Evernote writes one `<div>`
    /// per *line*, and writes an explicit `<div><br/></div>` where the author wanted a blank
    /// line. Treating every div as its own paragraph destroys that: consecutive lines become
    /// double-spaced and the author's real paragraph breaks disappear.
    enum Fragment {
        /// A visual line. Adjacent lines join into one block.
        case line(String)
        /// Self-contained output (list, table, heading, quote, code fence, fallback).
        case block(String)
        /// A line that is entirely monospace. Consecutive ones fuse into one fenced block.
        case codeLine(String)
        /// A blank line: ends whatever block is being accumulated.
        case paragraphBreak
    }

    func renderBlocks(_ nodes: [ENMLNode], listDepth: Int) -> [String] {
        assemble(renderFragments(nodes, listDepth: listDepth))
    }

    /// Top-level entry: the spacing policy applies to the note as a whole, not to each nested
    /// container, because "does this note double-space everything" is a note-level question.
    func renderDocument(
        _ nodes: [ENMLNode],
        spacing: MarkdownRenderer.Spacing
    ) -> [String] {
        var fragments = renderFragments(nodes, listDepth: 0)
        if spacing == .tight { fragments = RenderState.tighten(fragments) }
        return assemble(fragments)
    }

    /// Drops single spacer lines when the note puts one after nearly every line.
    ///
    /// Runs of two or more spacers survive as a single blank line: those are emphatic breaks
    /// even in a note that otherwise double-spaces everything.
    static func tighten(_ fragments: [Fragment]) -> [Fragment] {
        var lines = 0
        var isolatedBreaks = 0
        var runLength = 0
        for fragment in fragments {
            switch fragment {
            case .paragraphBreak:
                runLength += 1
            default:
                if runLength == 1 { isolatedBreaks += 1 }
                runLength = 0
                if case .line = fragment { lines += 1 }
            }
        }
        if runLength == 1 { isolatedBreaks += 1 }

        // Only when the habit is pervasive: at least five lines, and a lone spacer after at
        // least half of them.
        guard lines >= 5, isolatedBreaks * 2 >= lines else { return fragments }

        var out: [Fragment] = []
        var pendingBreaks = 0
        func flushBreaks() {
            if pendingBreaks >= 2 { out.append(.paragraphBreak) }
            pendingBreaks = 0
        }
        for fragment in fragments {
            if case .paragraphBreak = fragment {
                pendingBreaks += 1
            } else {
                flushBreaks()
                out.append(fragment)
            }
        }
        flushBreaks()
        return out
    }

    /// Joins adjacent fragments into blocks: runs of lines become paragraphs, runs of code
    /// lines become a single fence, and `paragraphBreak` ends whatever is accumulating.
    private func assemble(_ fragments: [Fragment]) -> [String] {
        var blocks: [String] = []
        var pending: [String] = []
        var code: [String] = []

        func flushProse() {
            guard !pending.isEmpty else { return }
            blocks.append(pending.joined(separator: "\n"))
            pending.removeAll()
        }
        func flushCode() {
            // A trailing blank line inside a listing is spacing, not content.
            while code.last?.isEmpty == true { code.removeLast() }
            guard !code.isEmpty else { return }
            blocks.append(codeFence(code.joined(separator: "\n")))
            code.removeAll()
        }

        for fragment in fragments {
            switch fragment {
            case .codeLine(let line):
                // Evernote writes one <div> per line, so a listing arrives as a run of separate
                // monospace divs. Fusing them back into one fence is the whole point.
                flushProse()
                code.append(line)

            case .line(let line):
                flushCode()
                // A task list must be its own block in both directions: prose running straight
                // into it would be swallowed as a list item, and prose straight after it would
                // become a lazy continuation of the last item.
                if let previous = pending.last,
                    RenderState.isTaskLine(line) != RenderState.isTaskLine(previous)
                {
                    flushProse()
                }
                pending.append(line)

            case .paragraphBreak:
                // A blank line in the middle of a listing stays part of the listing.
                if !code.isEmpty {
                    code.append("")
                } else {
                    flushProse()
                }

            case .block(let block):
                flushCode()
                flushProse()
                blocks.append(block)
            }
        }
        flushCode()
        flushProse()
        return blocks
    }

    private static func isTaskLine(_ line: String) -> Bool {
        line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ")
    }

    /// Walks a run of sibling nodes, gathering inline content into lines and delegating
    /// block-level elements.
    private func renderFragments(_ nodes: [ENMLNode], listDepth: Int) -> [Fragment] {
        var out: [Fragment] = []
        var inlineBuffer: [ENMLNode] = []

        func flushInline() {
            guard !inlineBuffer.isEmpty else { return }
            var buffer = inlineBuffer
            inlineBuffer.removeAll()

            // `<en-note><en-todo/>text` — a checklist row that never got wrapped in a div.
            var checkbox: String?
            if let index = firstMeaningfulIndex(buffer), index == 0 || buffer.count > index,
                case .element(let candidate) = buffer[index],
                candidate.name.lowercased() == "en-todo"
            {
                let checked = (candidate["checked"] ?? "false").lowercased() == "true"
                checkbox = checked ? "- [x] " : "- [ ] "
                buffer.remove(at: index)
            }

            let lines = paragraphLines(renderInline(buffer))
            if lines.isEmpty {
                out.append(.paragraphBreak)
            } else if let checkbox {
                out.append(.line(checkbox + lines.joined(separator: " ")))
            } else {
                out.append(contentsOf: lines.map(Fragment.line))
            }
        }

        for node in nodes {
            switch node {
            case .text(let text):
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
                    out.append(contentsOf: fragments(for: element, listDepth: listDepth))
                } else {
                    inlineBuffer.append(node)
                }
            }
        }
        flushInline()
        return out
    }

    private func fragments(for element: ENMLElement, listDepth: Int) -> [Fragment] {
        let name = element.name.lowercased()

        switch name {
        case "en-note", "center", "td", "th", "caption":
            return renderFragments(element.children, listDepth: listDepth)

        case "div":
            if let fence = evernoteCodeBlock(element) { return [.block(fence)] }
            if isEntirelyMonospace(element) {
                return [.codeLine(trimmedTrailingNewlines(plainText(element)))]
            }
            if let task = taskLine(for: element) { return [.line(task)] }
            let inner = renderFragments(element.children, listDepth: listDepth)
            // An empty div is Evernote's blank line, not nothing.
            return inner.isEmpty ? [.paragraphBreak] : inner

        case "p":
            // <p> really is a paragraph, unlike Evernote's <div>.
            if let fence = evernoteCodeBlock(element) { return [.block(fence)] }
            if isEntirelyMonospace(element) {
                return [.codeLine(trimmedTrailingNewlines(plainText(element)))]
            }
            let inner = renderFragments(element.children, listDepth: listDepth)
            return inner.isEmpty ? [.paragraphBreak] : [.paragraphBreak] + inner + [.paragraphBreak]

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(name.dropFirst()) ?? 1
            let text = singleLine(renderInline(element.children))
            guard !text.isEmpty else { return [] }
            return [.block("\(String(repeating: "#", count: level)) \(text)")]

        case "ul":
            return renderList(element, ordered: false, listDepth: listDepth).map(Fragment.block)

        case "ol":
            return renderList(element, ordered: true, listDepth: listDepth).map(Fragment.block)

        case "li":
            // A stray <li> outside any list; render its content rather than dropping it.
            return renderFragments(element.children, listDepth: listDepth)

        case "table":
            return renderTable(element, listDepth: listDepth).map(Fragment.block)

        case "thead", "tbody", "tfoot", "tr", "colgroup", "col":
            return renderFragments(element.children, listDepth: listDepth)

        case "blockquote":
            let inner = renderBlocks(element.children, listDepth: listDepth)
            guard !inner.isEmpty else { return [] }
            let quoted = inner.joined(separator: "\n\n")
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
            return [.block(quoted)]

        case "pre":
            return [.block(codeFence(plainText(element)))]

        case "hr":
            return [.block("---")]

        default:
            return [.block(fallback(element, reason: "unmapped-element:\(name)"))]
        }
    }

    /// A block container whose first meaningful child is `<en-todo>` is a checklist row.
    ///
    /// `<div><en-todo checked="true"/>text</div>` is the shape Evernote's own checklists use —
    /// far more common in real exports than `<li><en-todo/>`. Rendering it as a bare glyph
    /// loses the checkbox entirely.
    private func taskLine(for element: ENMLElement) -> String? {
        var children = element.children
        guard let index = firstMeaningfulIndex(children),
            case .element(let candidate) = children[index],
            candidate.name.lowercased() == "en-todo"
        else { return nil }

        let checked = (candidate["checked"] ?? "false").lowercased() == "true"
        children.remove(at: index)
        let text = singleLine(renderInline(children))
        return checked ? "- [x] \(text)" : "- [ ] \(text)"
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
        // A monospace run inside a line is Evernote's inline code.
        if RenderState.declaresMonospace(element) {
            let text = plainText(element)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("\n") {
                return codeSpan(text.trimmingCharacters(in: .whitespaces))
            }
        }
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
                out += RenderState.normalizeSpaces(text)
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

    /// Monospace families that reliably mean "this is code" when Evernote has no code-block
    /// marker. Deliberately a closed list: guessing from an arbitrary font would turn prose
    /// into code blocks, which is worse than leaving code as prose.
    private static let monospaceFamilies = [
        "courier", "monaco", "consolas", "menlo", "monospace", "lucida console",
        "andale mono", "dejavu sans mono", "roboto mono", "source code pro", "sf mono",
        "ibm plex mono", "fira code", "inconsolata", "pt mono", "liberation mono",
    ]

    /// A fenced code block when Evernote explicitly marked this container as one.
    private func evernoteCodeBlock(_ element: ElementAlias) -> String? {
        guard let style = element["style"],
            style.replacingOccurrences(of: " ", with: "").lowercased().contains("en-codeblock:true")
        else { return nil }
        return codeFence(plainText(element))
    }

    private func trimmedTrailingNewlines(_ text: String) -> String {
        var out = text
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    /// True when every text-bearing descendant sits inside a monospace font, and at least one
    /// such font is actually declared.
    private func isEntirelyMonospace(_ element: ElementAlias) -> Bool {
        var sawMonospace = false
        var sawUnstyledText = false

        func walk(_ node: ENMLNode, inMonospace: Bool) {
            switch node {
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                if inMonospace { sawMonospace = true } else { sawUnstyledText = true }
            case .element(let child):
                let nested = inMonospace || RenderState.declaresMonospace(child)
                for grandchild in child.children { walk(grandchild, inMonospace: nested) }
            }
        }

        for child in element.children {
            walk(child, inMonospace: RenderState.declaresMonospace(element))
        }
        return sawMonospace && !sawUnstyledText
    }

    /// Whether this element itself declares a monospace font, via `face=` or `font-family:`.
    static func declaresMonospace(_ node: ENMLElement) -> Bool {
        let face = (node["face"] ?? "").lowercased()
        let style = (node["style"] ?? "").lowercased()
        let declaresFamily = style.contains("font-family")
        return monospaceFamilies.contains { family in
            face.contains(family) || (declaresFamily && style.contains(family))
        }
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

    /// Splits accumulated inline text into visual lines: trailing whitespace trimmed, blank
    /// lines dropped, line-leading Markdown syntax escaped.
    ///
    /// Lines are later joined with a plain newline rather than a backslash hard break. Obsidian
    /// — the stated primary target — renders a single newline as a line break, and hundreds of
    /// trailing backslashes make the source unreadable. Strict CommonMark treats these as soft
    /// breaks; the plan's Phase 2 output-flavour toggle is where that becomes selectable.
    private func paragraphLines(_ text: String) -> [String] {
        text
            .components(separatedBy: "\n")
            .map { line in
                // Both ends: a stray leading space misaligns list markers, and four of them
                // would turn the line into an indented code block.
                line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            }
            .filter { !$0.isEmpty }
            .map(escapeLineStart)
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

    /// Collapses the exotic space characters Evernote writes into ordinary spaces.
    ///
    /// Evernote uses U+00A0 as its everyday word separator — 13,727 of them in a single 115 KB
    /// real notebook, a quarter of all characters. Left alone, `grep` and Obsidian search stop
    /// matching ordinary queries, which defeats the point of the archive. Whitespace is
    /// explicitly outside the losslessness contract ("modulo whitespace"), so normalising is safe.
    static func normalizeSpaces(_ text: String) -> String {
        guard text.contains(where: { RenderState.exoticSpaces.contains($0) }) else { return text }
        return String(
            text.map { RenderState.exoticSpaces.contains($0) ? " " : $0 }
        )
    }

    private static let exoticSpaces: Set<Character> = [
        "\u{00A0}",  // no-break space
        "\u{2007}",  // figure space
        "\u{202F}",  // narrow no-break space
        "\u{2009}",  // thin space
        "\u{200B}",  // zero-width space
    ]

    /// Escapes the inline Markdown metacharacters. Deliberately narrow: `_` is only escaped at
    /// word boundaries and `~` only when doubled, so ordinary prose and snake_case identifiers
    /// do not acquire backslashes they do not need.
    func escapeInline(_ rawText: String) -> String {
        guard !rawText.isEmpty else { return "" }
        let text = RenderState.normalizeSpaces(rawText)
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
