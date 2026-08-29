import Foundation

/// One `<note>` from an ENEX file, carried in the shape the renderer and writer need.
///
/// This model is frozen at the end of WP-2: WP-3 (rendering) and WP-4 (writing) both depend
/// on it and must not extend it independently.
struct Note {
    /// `<title>`. May be empty, may contain anything — see `Slug` for filename safety.
    var title: String
    /// Raw ENML from `<content>`, still wrapped in `<en-note>` and still carrying its DOCTYPE.
    var content: String
    var created: Date?
    var updated: Date?
    /// `<tag>` elements in document order, duplicates removed, order preserved.
    var tags: [String]
    /// Children of `<note-attributes>`, keyed by element name (`source-url`, `author`, ...).
    var attributes: [String: String]
    /// `<resource>` elements in document order.
    var resources: [Resource]

    /// Index of this note's resources by MD5, which is how `<en-media>` refers to them.
    ///
    /// A note can legally carry two resources with identical bytes; first-wins keeps the
    /// mapping deterministic.
    func resourcesByHash() -> [String: Resource] {
        var index: [String: Resource] = [:]
        for resource in resources where index[resource.md5] == nil {
            index[resource.md5] = resource
        }
        return index
    }

    var sourceURL: String? {
        attributes["source-url"]
    }

    var author: String? {
        attributes["author"]
    }
}

/// ENEX timestamps are always `yyyyMMdd'T'HHmmss'Z'` in UTC.
enum ENEXDate {
    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 16 else { return nil }
        let formatter = makeFormatter()
        return formatter.date(from: trimmed)
    }

    /// ISO-8601 UTC, which is what lands in the YAML frontmatter.
    static func iso8601(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    /// A fresh formatter each call is wasteful in a hot loop; callers that parse per-note
    /// (`ENEXParser`) hold one instead.
    static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }
}
