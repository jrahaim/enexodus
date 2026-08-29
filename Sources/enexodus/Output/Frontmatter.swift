import Foundation

/// Emits the YAML frontmatter block that heads every converted note.
///
/// Field order is fixed (plan §4 WP-4.4) so that re-running the converter produces byte-identical
/// files and `git diff` stays empty.
enum Frontmatter {

    static func render(
        note: Note,
        notebook: String,
        sourceFile: String
    ) -> String {
        var lines = ["---"]
        lines.append("title: \(quoted(note.title))")
        if let created = note.created {
            lines.append("created: \(ENEXDate.iso8601(created))")
        }
        if let updated = note.updated {
            lines.append("updated: \(ENEXDate.iso8601(updated))")
        }
        lines.append("tags: [\(note.tags.map(scalar).joined(separator: ", "))]")
        if let sourceURL = note.sourceURL, !sourceURL.isEmpty {
            lines.append("source-url: \(quoted(sourceURL))")
        }
        lines.append("notebook: \(quoted(notebook))")
        lines.append("enex-source: \(quoted(sourceFile))")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// A double-quoted YAML scalar. Used wherever the value is arbitrary user text.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                    for scalar in character.unicodeScalars {
                        out += String(format: "\\x%02x", scalar.value)
                    }
                } else {
                    out.append(character)
                }
            }
        }
        return out + "\""
    }

    /// Bare when the value is unambiguous YAML, quoted otherwise.
    ///
    /// Keeps ordinary tags reading as `tags: [work, receipts]` while a tag containing a comma,
    /// colon, or a YAML boolean word still round-trips correctly.
    static func scalar(_ value: String) -> String {
        guard !value.isEmpty else { return quoted(value) }
        if reservedWords.contains(value.lowercased()) { return quoted(value) }

        guard let first = value.first, first.isLetter || first.isNumber else { return quoted(value) }
        guard let last = value.last, last != " " else { return quoted(value) }

        let allowedPunctuation = Set<Character>(" _.-/+()'&!?")
        let isPlain = value.allSatisfy { character in
            character.isLetter || character.isNumber || allowedPunctuation.contains(character)
        }
        // A digit-leading value that parses as a number would come back as a number, not a string.
        if isPlain, first.isNumber, Double(value) != nil { return quoted(value) }
        return isPlain ? value : quoted(value)
    }

    private static let reservedWords: Set<String> = [
        "true", "false", "yes", "no", "on", "off", "null", "~", "y", "n",
    ]
}
