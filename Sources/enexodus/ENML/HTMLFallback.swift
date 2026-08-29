import Foundation

/// Marker written immediately before every inline-HTML fallback block.
///
/// It exists so the fallback is auditable two ways: a human reading the note can see that the
/// converter gave up on a subtree, and `enexodus verify` can count fallbacks by scanning the
/// vault without re-running the renderer.
let htmlFallbackMarkerPrefix = "<!-- enexodus:html-fallback"

/// Marker written where an `<en-media>` names a hash no resource in the note matches.
let orphanMediaMarkerPrefix = "<!-- enexodus:missing-resource"

/// Serializes ENML subtrees the Markdown mapping cannot represent as sanitized inline HTML.
///
/// The contract is losslessness, not beauty: structure and text survive intact, and only
/// actively dangerous constructs (script, iframe, event handlers, `javascript:` URLs) are
/// removed. Nothing else is dropped.
enum HTMLFallback {

    /// Elements removed wholesale. Their content is executable or remote, never note prose.
    static let droppedElements: Set<String> = ["script", "iframe", "object", "embed", "applet"]

    /// HTML void elements, emitted self-closed.
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr", "en-media", "en-todo",
    ]

    /// Attributes whose values are URLs and therefore need scheme checking.
    static let urlAttributes: Set<String> = [
        "href", "src", "action", "formaction", "data", "poster", "background", "xlink:href",
    ]

    static let blockedSchemes = ["javascript:", "vbscript:", "data:text/html"]

    /// A complete fallback block: marker comment, then the sanitized subtree on the next line.
    ///
    /// The block carries no internal blank lines, so CommonMark treats it as a single raw-HTML
    /// block rather than letting a stray blank line drop it back into Markdown parsing.
    static func block(for element: ENMLElement, reason: String, resources: ResourceIndex) -> String {
        let html = collapseBlankLines(serialize(.element(element), resources: resources))
        return "\(htmlFallbackMarkerPrefix) reason=\"\(escapeAttribute(reason))\" -->\n\(html)"
    }

    /// Fallback for ENML that would not parse at all, so there is no tree to walk.
    ///
    /// Sanitization here is regex-based and deliberately conservative — it is reached only when
    /// the document is already malformed, and the priority is that the note keeps its text.
    static func rawBlock(_ rawENML: String, reason: String) -> String {
        var html = rawENML
        html = ENMLDocument.stripDoctype(html)
        for element in droppedElements {
            html = removeElement(named: element, from: html)
        }
        html = stripEventHandlers(html)
        html = stripDangerousURLs(html)
        html = collapseBlankLines(html.trimmingCharacters(in: .whitespacesAndNewlines))
        return "\(htmlFallbackMarkerPrefix) reason=\"\(escapeAttribute(reason))\" -->\n\(html)"
    }

    // MARK: - Tree serialization

    static func serialize(_ node: ENMLNode, resources: ResourceIndex) -> String {
        switch node {
        case .text(let text):
            return escapeText(text)

        case .element(let element):
            let name = element.name.lowercased()
            if droppedElements.contains(name) { return "" }

            // Keep attachments reachable even inside a fallback subtree — an image in a
            // colspan table would otherwise become an unresolvable `<en-media>` tag.
            if name == "en-media" {
                return serializeMedia(element, resources: resources)
            }
            if name == "en-todo" {
                let checked = (element["checked"] ?? "false").lowercased() == "true"
                return checked ? "\u{2611}" : "\u{2610}"
            }

            let attributes = sanitizedAttributes(element.attributes)
            let open = attributes.isEmpty ? name : "\(name) \(attributes)"

            if voidElements.contains(name) || element.children.isEmpty {
                if voidElements.contains(name) { return "<\(open)/>" }
                return "<\(open)></\(name)>"
            }

            let inner = element.children.map { serialize($0, resources: resources) }.joined()
            return "<\(open)>\(inner)</\(name)>"
        }
    }

    private static func serializeMedia(_ element: ENMLElement, resources: ResourceIndex) -> String {
        let hash = (element["hash"] ?? "").lowercased()
        guard let resolved = resources.resolve(hash) else {
            let mime = element["type"] ?? ""
            return "\(orphanMediaMarkerPrefix) hash=\"\(escapeAttribute(hash))\" mime=\"\(escapeAttribute(mime))\" -->"
        }
        let path = escapeAttribute(resolved.relativePath)
        let name = escapeAttribute(resolved.displayName)
        if resolved.isImage {
            return "<img src=\"\(path)\" alt=\"\(name)\"/>"
        }
        return "<a href=\"\(path)\">\(escapeText(resolved.displayName))</a>"
    }

    private static func sanitizedAttributes(_ attributes: [String: String]) -> String {
        attributes
            .filter { name, value in
                let lower = name.lowercased()
                if lower.hasPrefix("on") { return false }
                if urlAttributes.contains(lower), isDangerousURL(value) { return false }
                return true
            }
            // Source order is already lost in XMLParser's dictionary; sorting makes output stable.
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key.lowercased())=\"\(escapeAttribute($0.value))\"" }
            .joined(separator: " ")
    }

    static func isDangerousURL(_ value: String) -> Bool {
        // Strip whitespace and control characters first: `java\nscript:` is the classic bypass.
        let compact = value.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0.value >= 0x20 }
            .map { String($0) }
            .joined()
            .lowercased()
        return blockedSchemes.contains { compact.hasPrefix($0) }
    }

    // MARK: - Escaping

    static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    /// A blank line inside a raw-HTML block ends the block in CommonMark, which would leave the
    /// remainder to be parsed as Markdown. Collapsing them keeps the block whole.
    static func collapseBlankLines(_ html: String) -> String {
        guard
            let regex = try? NSRegularExpression(pattern: "\\n[ \\t]*(?:\\n[ \\t]*)+", options: [])
        else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "\n")
    }

    // MARK: - Regex sanitization (raw path only)

    private static func removeElement(named name: String, from html: String) -> String {
        let pattern = "<\(name)\\b[^>]*>[\\s\\S]*?</\(name)\\s*>|<\(name)\\b[^>]*/>"
        return replacing(pattern, in: html, with: "")
    }

    private static func stripEventHandlers(_ html: String) -> String {
        replacing("\\son[a-zA-Z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", in: html, with: "")
    }

    private static func stripDangerousURLs(_ html: String) -> String {
        var result = html
        for scheme in blockedSchemes {
            let escaped = NSRegularExpression.escapedPattern(for: scheme)
            result = replacing(
                "(href|src|action|formaction|poster)\\s*=\\s*(\"\\s*\(escaped)[^\"]*\"|'\\s*\(escaped)[^']*')",
                in: result,
                with: "$1=\"\""
            )
        }
        return result
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
