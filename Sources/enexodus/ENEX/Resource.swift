import Foundation

/// A single `<resource>` from an ENEX note: the decoded bytes plus everything needed to
/// name the file on disk and match it back to an `<en-media>` reference.
struct Resource {
    /// Decoded bytes of `<data encoding="base64">`.
    var data: Data
    /// `<mime>`, e.g. `image/png`. Empty when the export omitted it.
    var mime: String
    /// Lowercase hex MD5 of `data`. This is the join key against `en-media/@hash`.
    var md5: String
    /// `<resource-attributes><file-name>`, when present.
    var fileName: String?
    /// `<resource-attributes><source-url>`, when present.
    var sourceURL: String?

    var isImage: Bool {
        mime.lowercased().hasPrefix("image/")
    }

    /// Filename extension implied by the MIME type, without the leading dot.
    ///
    /// Falls back to the extension of `fileName`, then to `bin`, so a resource is never
    /// written without one.
    var mimeExtension: String {
        let normalized = mime.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if let known = Resource.mimeExtensions[normalized.trimmingCharacters(in: .whitespaces)] {
            return known
        }
        if let name = fileName {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        // `image/svg+xml` -> `svg+xml` -> `svg`; a last-ditch guess before `bin`.
        if let subtype = normalized.split(separator: "/").last {
            let cleaned = subtype.split(separator: "+").first.map(String.init) ?? String(subtype)
            if !cleaned.isEmpty, cleaned.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return cleaned
            }
        }
        return "bin"
    }

    /// MIME types Evernote actually emits, plus the common attachment types.
    /// Anything absent falls through to the heuristics in `mimeExtension`.
    static let mimeExtensions: [String: String] = [
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/jpg": "jpg",
        "image/gif": "gif",
        "image/bmp": "bmp",
        "image/tiff": "tiff",
        "image/webp": "webp",
        "image/heic": "heic",
        "image/svg+xml": "svg",
        "application/pdf": "pdf",
        "application/zip": "zip",
        "application/json": "json",
        "application/rtf": "rtf",
        "application/msword": "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/octet-stream": "bin",
        "text/plain": "txt",
        "text/html": "html",
        "text/csv": "csv",
        "audio/mpeg": "mp3",
        "audio/mp4": "m4a",
        "audio/wav": "wav",
        "audio/x-wav": "wav",
        "audio/amr": "amr",
        "video/mp4": "mp4",
        "video/quicktime": "mov",
    ]
}
