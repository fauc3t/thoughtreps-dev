import Foundation

/// Limits and naming for files attached to a thought. Shared with the share extension, which
/// applies the same size cap before copying a file into the inbox.
enum FileAttachment {
    /// Largest file stored, in bytes. Images are processed instead and are not held to it.
    static let maxBytes = 5 * 1024 * 1024
    static let tooLargeMessage = "Files can be up to 5 MB."
    static let maxFilenameBytes = 200

    /// A name that is safe to show and to write to a temporary file: no path separators, colons or
    /// control characters, no leading dots, at most `maxFilenameBytes` UTF-8 bytes (whole characters) with the extension kept.
    static func sanitizedFilename(_ raw: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:").union(.illegalCharacters)
        var name = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            banned.contains($0) || $0.properties.generalCategory == .control ? "_" : $0
        }))
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.utf8.count > maxFilenameBytes {
            let ext = (name as NSString).pathExtension
            let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
            var kept = ""
            var bytes = suffix.utf8.count
            for character in name.dropLast(suffix.count) {
                bytes += String(character).utf8.count
                if bytes > maxFilenameBytes { break }
                kept.append(character)
            }
            name = kept + suffix
        }
        return name.isEmpty ? "File" : name
    }
}
