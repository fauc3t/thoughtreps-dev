import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SharedContent {
    /// Text first, then the URL on its own line, unless the text already contains the URL.
    static func merge(text: String?, url: URL?) -> String {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url else { return text }
        let link = url.absoluteString
        if text.isEmpty { return link }
        if text.contains(link) { return text }
        return text + "\n" + link
    }

    /// Largest shared file we read, in bytes. Share extensions have a tight memory limit.
    static let maxFileBytes = 1_000_000

    enum FileError: Error, Equatable {
        case tooLarge
        case notUTF8

        /// Shown after "Couldn't read the file".
        var reason: String {
            switch self {
            case .tooLarge: "It's larger than 1 MB."
            case .notUTF8: "It isn't UTF-8 text."
            }
        }
    }

    private static let markdown = UTType("net.daringfireball.markdown")

    /// The first Markdown or plain-text type among a provider's registered types.
    static func textType(in identifiers: [String]) -> UTType? {
        identifiers.lazy.compactMap { UTType($0) }.first { type in
            type.conforms(to: .plainText) || (markdown.map(type.conforms(to:)) ?? false)
        }
    }

    /// Inline text never registers Markdown or a file URL, so either marks a file attachment.
    static func isFile(typeIdentifiers identifiers: [String]) -> Bool {
        identifiers.lazy.compactMap { UTType($0) }.contains { type in
            type.conforms(to: .fileURL) || (markdown.map(type.conforms(to:)) ?? false)
        }
    }

    /// The type to load from a provider that carries a file or an image to attach, or nil for text,
    /// web links and anything else. Markdown and plain-text files are read as text instead.
    static func attachmentType(in identifiers: [String]) -> UTType? {
        let types = identifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .text) || (markdown.map($0.conforms(to:)) ?? false) }) { return nil }
        if let image = types.first(where: { $0.conforms(to: .image) }) { return image }
        guard types.contains(where: { $0.conforms(to: .fileURL) }) else { return nil }
        return types.first { $0.conforms(to: .data) && !$0.conforms(to: .url) } ?? .item
    }

    /// Whether the app can process this as a photo (and so skips the 5 MB file cap): an image type that
    /// ImageIO recognizes. Reads the header only, so memory stays flat.
    static func isDecodableImage(type: UTType, at url: URL) -> Bool {
        guard type.conforms(to: .image), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    /// Whether a shared file is refused for size: over the file cap, and not a photo the app can process.
    static func exceedsFileCap(type: UTType, at url: URL, size: Int) -> Bool {
        size > FileAttachment.maxBytes && !isDecodableImage(type: type, at: url)
    }

    /// Whether a file of this type is processed as a photo, which the 5 MB file cap doesn't apply to.
    static func isImage(typeIdentifier: String) -> Bool {
        UTType(typeIdentifier)?.conforms(to: .image) == true
    }

    /// Decodes a shared Markdown/plain-text file verbatim: strips a UTF-8 BOM and normalizes CRLF and CR to LF.
    static func text(fromFileData data: Data) throws -> String {
        guard data.count <= maxFileBytes else { throw FileError.tooLarge }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body = data.starts(with: bom) ? data.dropFirst(bom.count) : data[...]
        guard let text = String(data: Data(body), encoding: .utf8) else { throw FileError.notUTF8 }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
