import Foundation

/// Turns arbitrary note and notebook titles into filenames that are safe on disk.
///
/// Evernote titles are unconstrained: they contain slashes, newlines, emoji, leading dots, and
/// in at least one real export, `../../etc/passwd`. Everything here exists to make sure a title
/// can only ever produce a single path component inside the notebook directory.
enum Slug {

    /// Well under every filesystem's per-component limit once `.md` and a collision suffix are
    /// appended, and short enough to stay readable in a file listing.
    static let maxLength = 120

    /// Characters that would either escape the directory or break a common filesystem.
    private static let unsafe = Set<Character>("/\\:*?\"<>|")

    /// Characters trimmed from both ends. Leading dots are the traversal-relevant ones: after
    /// separators are replaced, `../../etc/passwd` becomes `..-..-etc-passwd`, and trimming
    /// leaves `etc-passwd`.
    private static let trimmable = Set<Character>(".- \t")

    static func make(_ raw: String, fallback: String = "untitled") -> String {
        var replaced = ""
        replaced.reserveCapacity(raw.count)

        for character in raw.precomposedStringWithCanonicalMapping {
            if character.isNewline || character == "\t" {
                replaced.append(" ")
            } else if character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                replaced.append("-")
            } else if unsafe.contains(character) {
                replaced.append("-")
            } else {
                replaced.append(character)
            }
        }

        // Collapse whitespace runs, then hyphen runs, so `a / b` does not become `a---b`.
        var collapsed = ""
        var previous: Character?
        for character in replaced {
            let isSpace = character == " "
            let isHyphen = character == "-"
            if let previous, (isSpace && previous == " ") || (isHyphen && previous == "-") {
                continue
            }
            collapsed.append(character)
            previous = character
        }
        var trimmed = trim(collapsed)
        if trimmed.count > maxLength {
            trimmed = trim(String(trimmed.prefix(maxLength)))
        }
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func trim(_ text: String) -> String {
        var result = Substring(text)
        while let first = result.first, trimmable.contains(first) { result.removeFirst() }
        while let last = result.last, trimmable.contains(last) { result.removeLast() }
        return String(result)
    }

    /// Appends `-2`, `-3`, ... until the name is unused, then records it.
    ///
    /// Comparison is case-insensitive because macOS filesystems are, and a vault written on
    /// macOS must not collide when read back on a case-sensitive Linux checkout.
    static func disambiguate(_ base: String, extension ext: String, used: inout Set<String>) -> String {
        var candidate = ext.isEmpty ? base : "\(base).\(ext)"
        var counter = 2
        while used.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// Filename for a resource: its own `<file-name>` when it has one, otherwise an
    /// MD5-derived name so the file is still identifiable and stable across runs.
    static func attachmentBaseName(for resource: Resource) -> (base: String, extension: String) {
        let hashStem = String(resource.md5.prefix(8))
        guard let raw = resource.fileName, !raw.isEmpty else {
            return (hashStem.isEmpty ? "attachment" : hashStem, resource.mimeExtension)
        }
        let name = raw as NSString
        let ext = name.pathExtension.isEmpty ? resource.mimeExtension : name.pathExtension.lowercased()
        let stem = make(name.deletingPathExtension, fallback: hashStem)
        return (stem, ext)
    }
}
