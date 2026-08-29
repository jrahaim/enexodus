import Foundation
import XCTest

@testable import enexodus

enum Fixtures {
    static var directory: URL {
        guard let resources = Bundle.module.resourceURL else {
            fatalError("test bundle has no resource directory")
        }
        return resources.appendingPathComponent("Fixtures", isDirectory: true)
    }

    static var expectedDirectory: URL {
        directory.appendingPathComponent("expected", isDirectory: true)
    }

    static let names = ["hostile", "media", "plain", "tables", "todos"]

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).enex")
    }

    static func notes(in name: String) throws -> [Note] {
        var collected: [Note] = []
        try ENEXParser.parse(fileURL: url(name)) { collected.append($0) }
        return collected
    }
}

/// Creates a directory that is removed when the test finishes.
func makeTemporaryDirectory(_ testCase: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("enexodus-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: url)
    }
    return url
}

/// Converts a whole fixture directory into `output`, the same way the CLI does.
func convertFixtures(into output: URL, clean: Bool = false) throws {
    for location in try VaultWriter.locations(forInputs: [Fixtures.directory]) {
        let writer = try VaultWriter(
            outputRoot: output,
            directoryName: location.directoryName,
            notebookName: location.notebookName,
            clean: clean
        )
        for fileURL in location.fileURLs {
            let sourceFile = fileURL.lastPathComponent
            try ENEXParser.parse(fileURL: fileURL) { _ = try writer.write($0, sourceFile: sourceFile) }
        }
    }
}

/// Every file under `root`, as paths relative to it, sorted.
func fileTree(at root: URL) throws -> [String] {
    let manager = FileManager.default
    guard
        let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
    else { return [] }

    var paths: [String] = []
    let prefix = root.standardizedFileURL.path + "/"
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        var path = url.standardizedFileURL.path
        if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        // Filenames come back decomposed on APFS; compare in the composed form the writer used.
        paths.append(path.precomposedStringWithCanonicalMapping)
    }
    return paths.sorted()
}

/// Implements the losslessness comparison from plan §6.1: the text content of the input ENML
/// must be contained in the text content of the output, modulo whitespace.
///
/// Containment is checked as a subsequence. The renderer only ever *adds* characters — emphasis
/// markers, link destinations, escape backslashes — and never reorders or removes text, so
/// subsequence containment holds exactly when nothing was lost. A word-multiset comparison was
/// tried first and rejected: `ENMLElement.textContent` concatenates sibling text nodes, so
/// `<li>a</li><li>b</li>` yields the word "ab", and conversely a word split across
/// `<span>` boundaries yields fragments — both produce failures that say nothing about the
/// converter.
enum Losslessness {

    /// All text beneath the tree, whitespace removed.
    static func sourceText(_ element: ENMLElement) -> String {
        stripWhitespace(element.textContent)
    }

    /// Rendered Markdown reduced to comparable text: HTML entities decoded (the fallback path
    /// escapes `<` to `&lt;`), Markdown escape backslashes removed, whitespace removed.
    static func outputText(_ markdown: String) -> String {
        stripWhitespace(removeEscapes(decodeEntities(markdown)))
    }

    /// The first character of `needle` that is not present, in order, in `haystack`, or nil when
    /// `needle` is a subsequence of it. Returned with context so a failure is diagnosable.
    static func firstMissing(_ needle: String, in haystack: String) -> String? {
        var cursor = haystack.startIndex
        var consumed = 0
        for character in needle {
            var found = false
            while cursor < haystack.endIndex {
                let candidate = haystack[cursor]
                cursor = haystack.index(after: cursor)
                if candidate == character {
                    found = true
                    break
                }
            }
            if !found {
                let start = needle.index(
                    needle.startIndex, offsetBy: max(0, consumed - 30)
                )
                let end = needle.index(
                    needle.startIndex, offsetBy: min(needle.count, consumed + 30)
                )
                return "…\(needle[start..<end])… (stopped at \(character))"
            }
            consumed += 1
        }
        return nil
    }

    private static func stripWhitespace(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#10;", "\n"), ("&#39;", "\'"),
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Ampersand last, so `&amp;lt;` does not become `<`.
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Drops the backslash from `\X` where X is ASCII punctuation, undoing Markdown escaping.
    private static func removeEscapes(_ text: String) -> String {
        var result = ""
        var iterator = Array(text)
        var index = 0
        while index < iterator.count {
            if iterator[index] == "\\", index + 1 < iterator.count {
                let next = iterator[index + 1]
                if next.isASCII, next.isPunctuation || next.isSymbol {
                    result.append(next)
                    index += 2
                    continue
                }
            }
            result.append(iterator[index])
            index += 1
        }
        return result
    }
}
