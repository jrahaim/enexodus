import Foundation

struct NoteOutcome {
    var fileName: String
    var title: String
    var attachmentsWritten: [String]
    var warnings: [RenderWarning]
    var mediaReferences: Int
    var orphanMediaReferences: Int
    var fallbackBlocks: Int
    var isBodyEmpty: Bool
}

/// One ENEX file and the vault directory it maps to.
///
/// ENEX carries no notebook name, so the export convention — one file per notebook, filename is
/// the notebook name (plan §2) — is the only source of it.
struct NotebookLocation {
    /// Usually one file. Evernote caps an export at 100 notes per file and suffixes the
    /// overflow — `My Notes.enex`, `My Notes (1).enex`, `My Notes (2).enex` — so one notebook
    /// can arrive as several files that must land in a single folder.
    var fileURLs: [URL]
    var notebookName: String
    var directoryName: String
}

/// Writes one notebook: `<output>/<notebook>/<note>.md` plus `<output>/<notebook>/_attachments/`.
///
/// Everything it emits is a pure function of the ENEX content and the order notes appear in the
/// file — no run timestamps, no hashing of wall-clock state — so converting twice into the same
/// directory produces byte-identical output.
final class VaultWriter {

    static let attachmentsDirectoryName = "_attachments"

    /// Resolves input paths — `.enex` files, directories of them, or a mix — into the notebooks
    /// to convert, each with its vault directory name.
    ///
    /// Sorted by filename and disambiguated in that order, so both `convert` and `verify`
    /// derive identical directory names without sharing state.
    static func locations(forInputs inputs: [URL], mergeSplitFiles: Bool = true) throws
        -> [NotebookLocation]
    {
        let manager = FileManager.default
        var enexFiles: [URL] = []

        for input in inputs {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: input.path])
            }
            if isDirectory.boolValue {
                enexFiles += try manager.contentsOfDirectory(
                    at: input,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                .filter { $0.pathExtension.lowercased() == "enex" }
            } else if input.pathExtension.lowercased() == "enex" {
                enexFiles.append(input)
            }
        }
        enexFiles.sort { $0.lastPathComponent < $1.lastPathComponent }

        // Group by notebook name, folding Evernote's split-export suffix when asked.
        var order: [String] = []
        var grouped: [String: [URL]] = [:]
        for url in enexFiles {
            let stem = url.deletingPathExtension().lastPathComponent
            let name = mergeSplitFiles ? splitExportBaseName(stem) : stem
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(url)
        }

        var used: Set<String> = []
        return order.map { name in
            let base = Slug.make(name, fallback: "notebook")
            let directoryName = Slug.disambiguate(base, extension: "", used: &used)
            return NotebookLocation(
                fileURLs: grouped[name] ?? [],
                notebookName: name,
                directoryName: directoryName
            )
        }
    }

    /// Strips Evernote's split-export suffix: `My Notes (2)` -> `My Notes`.
    ///
    /// Only a parenthesised integer at the very end counts, so a notebook genuinely named
    /// `Recipes (old)` is left alone.
    static func splitExportBaseName(_ stem: String) -> String {
        guard stem.hasSuffix(")"), let open = stem.lastIndex(of: "(") else { return stem }
        let inside = stem[stem.index(after: open)..<stem.index(before: stem.endIndex)]
        guard !inside.isEmpty, inside.allSatisfy(\.isNumber) else { return stem }
        let base = stem[stem.startIndex..<open].trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? stem : base
    }

    let notebookName: String
    let directory: URL
    let spacing: MarkdownRenderer.Spacing

    private let fileManager = FileManager.default
    private let attachmentsDirectory: URL
    private var attachmentsDirectoryCreated = false

    private var usedNoteFileNames: Set<String> = []
    private var usedAttachmentFileNames: Set<String> = []
    /// Identical bytes are written once and linked from every note that references them.
    private var attachmentNameByHash: [String: String] = [:]

    private(set) var notesWritten = 0

    init(
        outputRoot: URL,
        directoryName: String,
        notebookName: String,
        clean: Bool,
        spacing: MarkdownRenderer.Spacing = .tight
    ) throws {
        self.notebookName = notebookName
        self.spacing = spacing
        self.directory = outputRoot.appendingPathComponent(directoryName, isDirectory: true)
        self.attachmentsDirectory = directory.appendingPathComponent(
            VaultWriter.attachmentsDirectoryName,
            isDirectory: true
        )

        if clean, fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func write(_ note: Note, sourceFile: String) throws -> NoteOutcome {
        let (index, written) = try writeResources(of: note)

        let renderer = MarkdownRenderer(resources: index, spacing: spacing)
        let rendered = renderer.renderENML(note.content)

        let baseName = Slug.make(note.title, fallback: "untitled")
        let fileName = Slug.disambiguate(baseName, extension: "md", used: &usedNoteFileNames)

        let frontmatter = Frontmatter.render(
            note: note,
            notebook: notebookName,
            sourceFile: sourceFile
        )
        let body = rendered.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let document = body.isEmpty ? "\(frontmatter)\n" : "\(frontmatter)\n\n\(body)\n"

        try Data(document.utf8).write(
            to: directory.appendingPathComponent(fileName),
            options: .atomic
        )
        notesWritten += 1

        var warnings = rendered.warnings
        if body.isEmpty {
            warnings.append(RenderWarning(kind: .emptyBody, detail: note.title))
        }

        return NoteOutcome(
            fileName: fileName,
            title: note.title,
            attachmentsWritten: written,
            warnings: warnings,
            mediaReferences: rendered.mediaReferences,
            orphanMediaReferences: rendered.orphanMediaReferences,
            fallbackBlocks: rendered.fallbackBlocks,
            isBodyEmpty: body.isEmpty
        )
    }

    /// Writes this note's resources and returns the hash index the renderer needs.
    ///
    /// Resources are written whether or not an `<en-media>` references them; an unreferenced
    /// attachment is a real thing in Evernote exports, and dropping it would lose data.
    /// `verify` reports the discrepancy instead.
    private func writeResources(of note: Note) throws -> (ResourceIndex, [String]) {
        var index: [String: ResolvedResource] = [:]
        var written: [String] = []

        for resource in note.resources {
            let fileName: String
            if let existing = attachmentNameByHash[resource.md5] {
                fileName = existing
            } else {
                let (base, ext) = Slug.attachmentBaseName(for: resource)
                fileName = Slug.disambiguate(base, extension: ext, used: &usedAttachmentFileNames)
                attachmentNameByHash[resource.md5] = fileName

                try ensureAttachmentsDirectory()
                try resource.data.write(
                    to: attachmentsDirectory.appendingPathComponent(fileName),
                    options: .atomic
                )
                written.append(fileName)
            }

            index[resource.md5] = ResolvedResource(
                relativePath: "\(VaultWriter.attachmentsDirectoryName)/\(fileName)",
                displayName: resource.fileName ?? fileName,
                isImage: resource.isImage
            )
        }

        return (ResourceIndex(byHash: index), written)
    }

    private func ensureAttachmentsDirectory() throws {
        guard !attachmentsDirectoryCreated else { return }
        try fileManager.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        attachmentsDirectoryCreated = true
    }
}
