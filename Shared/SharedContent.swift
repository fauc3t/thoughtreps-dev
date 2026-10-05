import Foundation
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

    /// Decodes a shared Markdown/plain-text file verbatim: strips a UTF-8 BOM and normalizes CRLF and CR to LF.
    static func text(fromFileData data: Data) throws -> String {
        guard data.count <= maxFileBytes else { throw FileError.tooLarge }
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let body = data.starts(with: bom) ? data.dropFirst(bom.count) : data[...]
        guard let text = String(data: Data(body), encoding: .utf8) else { throw FileError.notUTF8 }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
