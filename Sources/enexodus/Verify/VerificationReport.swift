import Foundation

// MARK: - Report shape

struct NotebookReport: Codable {
    var notebook: String
    var enexFile: String
    var directory: String

    /// Counted by re-parsing the ENEX.
    var enexNotes: Int
    var enexResources: Int
    var enexMediaReferences: Int

    /// Counted by scanning the written vault. Deliberately never derived from the numbers above.
    var markdownFiles: Int
    var attachmentFiles: Int
    var vaultMediaReferences: Int

    var orphanMediaReferences: Int
    var fallbackBlocks: Int
    var emptyBodyNotes: Int
    var unreferencedAttachments: Int
    var danglingAttachmentLinks: [String]
    var problems: [String]

    var ok: Bool { problems.isEmpty }
}

struct VerificationTotals: Codable {
    var notebooks = 0
    var enexNotes = 0
    var enexResources = 0
    var enexMediaReferences = 0
    var markdownFiles = 0
    var attachmentFiles = 0
    var vaultMediaReferences = 0
    var orphanMediaReferences = 0
    var fallbackBlocks = 0
    var emptyBodyNotes = 0
    var unreferencedAttachments = 0
    var problems = 0
}

struct VerificationReport: Codable {
    var notebooks: [NotebookReport]
    var totals: VerificationTotals
    var ok: Bool
}

// MARK: - Verifier

/// Cross-checks a converted vault against the ENEX it came from.
///
/// The two sides are computed independently on purpose (plan §6.4): the ENEX side re-parses the
/// export, the vault side reads only the files on disk. Neither number is derived from the other,
/// so a bug in the writer cannot make the check agree with itself.
struct Verifier {

    var inputDirectory: URL
    var outputDirectory: URL

    func run() throws -> VerificationReport {
        let locations = try VaultWriter.locations(inInputDirectory: inputDirectory)
        var reports: [NotebookReport] = []
        var totals = VerificationTotals()

        for location in locations {
            let report = try verify(location)
            reports.append(report)

            totals.notebooks += 1
            totals.enexNotes += report.enexNotes
            totals.enexResources += report.enexResources
            totals.enexMediaReferences += report.enexMediaReferences
            totals.markdownFiles += report.markdownFiles
            totals.attachmentFiles += report.attachmentFiles
            totals.vaultMediaReferences += report.vaultMediaReferences
            totals.orphanMediaReferences += report.orphanMediaReferences
            totals.fallbackBlocks += report.fallbackBlocks
            totals.emptyBodyNotes += report.emptyBodyNotes
            totals.unreferencedAttachments += report.unreferencedAttachments
            totals.problems += report.problems.count
        }

        return VerificationReport(
            notebooks: reports,
            totals: totals,
            ok: totals.problems == 0
        )
    }

    // MARK: ENEX side

    private func verify(_ location: NotebookLocation) throws -> NotebookReport {
        var notes = 0
        var hashes: Set<String> = []
        var mediaReferences = 0

        try ENEXParser.parse(fileURL: location.fileURL) { note in
            notes += 1
            for resource in note.resources { hashes.insert(resource.md5) }
            mediaReferences += Verifier.countOccurrences(of: "<en-media", in: note.content)
        }

        let directory = outputDirectory.appendingPathComponent(
            location.directoryName,
            isDirectory: true
        )
        let vault = try scanVault(at: directory)

        var problems: [String] = []
        if !vault.directoryExists {
            problems.append("notebook directory is missing: \(location.directoryName)")
        }
        if notes != vault.markdownFiles {
            problems.append("note count mismatch: \(notes) in ENEX, \(vault.markdownFiles) .md files")
        }
        if hashes.count != vault.attachmentFiles {
            problems.append(
                "attachment count mismatch: \(hashes.count) distinct resources in ENEX, "
                    + "\(vault.attachmentFiles) files in \(VaultWriter.attachmentsDirectoryName)/"
            )
        }
        if mediaReferences != vault.mediaReferences {
            problems.append(
                "en-media reference mismatch: \(mediaReferences) in ENEX, "
                    + "\(vault.mediaReferences) in Markdown"
            )
        }
        for dangling in vault.danglingLinks {
            problems.append("link points at a missing attachment: \(dangling)")
        }

        return NotebookReport(
            notebook: location.notebookName,
            enexFile: location.fileURL.lastPathComponent,
            directory: location.directoryName,
            enexNotes: notes,
            enexResources: hashes.count,
            enexMediaReferences: mediaReferences,
            markdownFiles: vault.markdownFiles,
            attachmentFiles: vault.attachmentFiles,
            vaultMediaReferences: vault.mediaReferences,
            orphanMediaReferences: vault.orphanMarkers,
            fallbackBlocks: vault.fallbackMarkers,
            emptyBodyNotes: vault.emptyBodyNotes,
            unreferencedAttachments: vault.unreferencedAttachments,
            danglingAttachmentLinks: vault.danglingLinks,
            problems: problems
        )
    }

    // MARK: Vault side

    private struct VaultScan {
        var directoryExists = false
        var markdownFiles = 0
        var attachmentFiles = 0
        var mediaReferences = 0
        var orphanMarkers = 0
        var fallbackMarkers = 0
        var emptyBodyNotes = 0
        var unreferencedAttachments = 0
        var danglingLinks: [String] = []
    }

    /// Reads the notebook directory and nothing else. No parser, no renderer, no shared helpers
    /// with the write path beyond the two marker constants.
    private func scanVault(at directory: URL) throws -> VaultScan {
        let fileManager = FileManager.default
        var scan = VaultScan()

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return scan
        }
        scan.directoryExists = true

        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let markdownFiles = entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        scan.markdownFiles = markdownFiles.count

        let attachmentsDirectory = directory.appendingPathComponent(
            VaultWriter.attachmentsDirectoryName,
            isDirectory: true
        )
        var attachmentNames: Set<String> = []
        if fileManager.fileExists(atPath: attachmentsDirectory.path) {
            let attachments = try fileManager.contentsOfDirectory(
                at: attachmentsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            attachmentNames = Set(attachments.map(\.lastPathComponent))
            scan.attachmentFiles = attachments.count
        }

        var referencedAttachments: Set<String> = []

        for file in markdownFiles {
            let text = try String(contentsOf: file, encoding: .utf8)

            let orphans = Verifier.countOccurrences(of: orphanMediaMarkerPrefix, in: text)
            let fallbacks = Verifier.countOccurrences(of: htmlFallbackMarkerPrefix, in: text)
            // An `<en-media>` surviving into the Markdown means a note fell back before its
            // resources could be resolved; it is still a media reference. `\<en-media` is
            // escaped note prose, not markup.
            let unresolved =
                Verifier.countOccurrences(of: "<en-media", in: text)
                - Verifier.countOccurrences(of: "\\<en-media", in: text)

            let links = Verifier.attachmentLinks(in: text)
            for link in links {
                referencedAttachments.insert(link)
                if !attachmentNames.contains(link) {
                    scan.danglingLinks.append("\(file.lastPathComponent) -> \(link)")
                }
            }

            scan.orphanMarkers += orphans
            scan.fallbackMarkers += fallbacks
            scan.mediaReferences += links.count + orphans + unresolved
            if Verifier.hasEmptyBody(text) { scan.emptyBodyNotes += 1 }
        }

        scan.unreferencedAttachments = attachmentNames.subtracting(referencedAttachments).count
        return scan
    }

    // MARK: Text scanning

    static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Attachment filenames referenced from a note, from both the Markdown link form
    /// `](_attachments/x)` and the HTML form emitted inside fallback blocks.
    ///
    /// Escaped occurrences (`\_attachments/`) are literal note text, not links, and are skipped
    /// because the renderer escapes a word-boundary underscore.
    static func attachmentLinks(in text: String) -> [String] {
        let marker = "\(VaultWriter.attachmentsDirectoryName)/"
        var results: [String] = []
        var searchRange = text.startIndex..<text.endIndex

        while let found = text.range(of: marker, range: searchRange) {
            searchRange = found.upperBound..<text.endIndex

            if found.lowerBound > text.startIndex {
                let previous = text.index(before: found.lowerBound)
                if text[previous] == "\\" { continue }
            }

            var cursor = found.upperBound
            var name = ""
            while cursor < text.endIndex {
                let character = text[cursor]
                if character == ")" || character == "\"" || character == ">" || character == "\n" {
                    break
                }
                name.append(character)
                cursor = text.index(after: cursor)
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { results.append(trimmed) }
        }
        return results
    }

    /// A note is empty when nothing but frontmatter was written.
    static func hasEmptyBody(_ text: String) -> Bool {
        guard text.hasPrefix("---\n") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let afterOpening = text.index(text.startIndex, offsetBy: 4)
        guard let close = text.range(of: "\n---\n", range: afterOpening..<text.endIndex)
        else {
            // Unterminated frontmatter: whatever follows is all there is.
            return text.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return text[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Human-readable rendering

extension VerificationReport {
    func textSummary() -> String {
        var lines: [String] = []
        let header = [
            "notebook", "notes", "md", "res", "att", "media", "linked", "orphan", "html", "empty",
        ]
        lines.append(header.joined(separator: "\t"))

        for report in notebooks {
            lines.append(
                [
                    report.notebook,
                    "\(report.enexNotes)",
                    "\(report.markdownFiles)",
                    "\(report.enexResources)",
                    "\(report.attachmentFiles)",
                    "\(report.enexMediaReferences)",
                    "\(report.vaultMediaReferences)",
                    "\(report.orphanMediaReferences)",
                    "\(report.fallbackBlocks)",
                    "\(report.emptyBodyNotes)",
                ].joined(separator: "\t")
            )
        }

        lines.append(
            [
                "TOTAL",
                "\(totals.enexNotes)",
                "\(totals.markdownFiles)",
                "\(totals.enexResources)",
                "\(totals.attachmentFiles)",
                "\(totals.enexMediaReferences)",
                "\(totals.vaultMediaReferences)",
                "\(totals.orphanMediaReferences)",
                "\(totals.fallbackBlocks)",
                "\(totals.emptyBodyNotes)",
            ].joined(separator: "\t")
        )

        let flagged = notebooks.filter { !$0.problems.isEmpty }
        if flagged.isEmpty {
            lines.append("")
            lines.append("OK: \(totals.notebooks) notebooks, \(totals.enexNotes) notes verified.")
        } else {
            lines.append("")
            for report in flagged {
                for problem in report.problems {
                    lines.append("FAIL [\(report.notebook)] \(problem)")
                }
            }
        }

        if totals.orphanMediaReferences > 0 {
            lines.append(
                "note: \(totals.orphanMediaReferences) en-media reference(s) matched no resource in the "
                    + "source ENEX; each is marked in the Markdown."
            )
        }
        if totals.unreferencedAttachments > 0 {
            lines.append(
                "note: \(totals.unreferencedAttachments) attachment(s) were written but are not "
                    + "referenced by any note body."
            )
        }
        return lines.joined(separator: "\n")
    }
}
