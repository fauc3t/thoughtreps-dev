import Foundation

/// The `![](img:<uuid>)` Markdown that places an inline image in a thought's body.
enum ImageToken {
    static let scheme = "img"

    private static let regex = try! NSRegularExpression(
        pattern: #"!\[[^\]\n]*\]\(img:([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)"#
    )

    static func token(for id: UUID) -> String {
        "![](\(scheme):\(id.uuidString))"
    }

    /// Image ids in text order, duplicates included. Tokens inside code spans or fenced code
    /// are literal text, not images.
    static func references(in body: String) -> [UUID] {
        let stripped = TagParser.stripCode(body) as NSString
        return regex.matches(in: stripped as String, range: NSRange(location: 0, length: stripped.length)).compactMap {
            UUID(uuidString: stripped.substring(with: $0.range(at: 1)))
        }
    }

    /// `body` without any image token (including ones in code, which are noise in text either way).
    static func removing(from body: String) -> String {
        regex.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
    }

    /// The image id for a Markdown image URL the renderer should load locally, or nil for any other URL.
    static func id(from url: URL) -> UUID? {
        let text = url.absoluteString
        guard text.lowercased().hasPrefix("\(scheme):") else { return nil }
        return UUID(uuidString: String(text.dropFirst(scheme.count + 1)))
    }
}
