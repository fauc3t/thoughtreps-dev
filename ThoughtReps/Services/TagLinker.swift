import Foundation

/// Rewrites `#tags` in Markdown into links with the `thoughtreps-tag:` scheme, so the renderer
/// can make them tappable. Uses `TagParser`'s rules; tags already inside a link are left alone.
enum TagLinker {
    static let scheme = "thoughtreps-tag"

    private static let keyAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
    // Inline links `[text](url)` and autolinks `<url>`; nested links aren't valid Markdown.
    private static let links = try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\([^)\n]*\)|<[^>\s]+>"#)

    static func link(_ markdown: String) -> String {
        let source = TagParser.normalized(markdown)
        let matches = TagParser.matches(in: source)
        guard !matches.isEmpty else { return markdown }

        let linkRanges = links.matches(
            in: TagParser.stripCode(source),
            range: NSRange(location: 0, length: (source as NSString).length)
        ).map(\.range)

        let ns = source as NSString
        let output = NSMutableString(string: source)
        for match in matches.reversed() {
            guard !linkRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  !isEscaped(at: match.range.location, in: ns) else { continue }
            let key = match.tag.key.addingPercentEncoding(withAllowedCharacters: keyAllowed) ?? match.tag.key
            let label = match.tag.display.replacingOccurrences(of: "_", with: "\\_")
            output.replaceCharacters(in: match.range, with: "[#\(label)](\(scheme):\(key))")
        }
        return output as String
    }

    /// True when the character at `index` is preceded by an odd number of backslashes.
    private static func isEscaped(at index: Int, in text: NSString) -> Bool {
        var count = 0
        var i = index - 1
        while i >= 0, text.character(at: i) == 0x5C {
            count += 1
            i -= 1
        }
        return count % 2 == 1
    }

    /// The tag key in a `thoughtreps-tag:` URL, or nil for any other URL.
    static func key(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return url.absoluteString.dropFirst(scheme.count + 1).removingPercentEncoding
    }
}
