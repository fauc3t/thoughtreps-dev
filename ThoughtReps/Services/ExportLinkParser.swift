import Foundation

/// A pasted or opened export link, split into the link id and the key from the `#` fragment.
struct ParsedExportLink: Equatable, Sendable {
    let id: String
    let key: String

    /// Accepts exactly `ExportLinkCrypto.linkBase` + a 22-character id + `#` + a 43-character key (the
    /// base64url shapes `ExportLinkCrypto` and the server generate), ignoring surrounding whitespace.
    static func parse(_ text: String) -> ParsedExportLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(ExportLinkCrypto.linkBase) else { return nil }
        let rest = trimmed.dropFirst(ExportLinkCrypto.linkBase.count)
        let parts = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, isBase64URL(parts[0], length: 22), isBase64URL(parts[1], length: 43) else { return nil }
        return ParsedExportLink(id: String(parts[0]), key: String(parts[1]))
    }

    private static func isBase64URL(_ text: Substring, length: Int) -> Bool {
        text.utf8.count == length && text.utf8.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D || $0 == 0x5F
        }
    }
}
