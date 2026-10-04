import Foundation

/// Finds `#hashtags` in Markdown.
///
/// Rules: a tag is `#` followed by letters, digits, `_` or `-`, containing at least one
/// letter (`#1` is not a tag). Headings (`# Title`), URL fragments (`site.com/#x`),
/// and anything inside inline code or fenced code blocks are ignored.
enum TagParser {
    struct ParsedTag: Equatable, Hashable {
        /// Lowercased key used for matching and storage.
        let key: String
        /// The spelling as written, without `#`.
        let display: String
    }

    // `#` not preceded by a word character, `#`, `/` or `&` (HTML entities),
    // then a tag that starts with a letter, digit or underscore (combining marks allowed after).
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_#/&])#([\p{L}\p{N}_][\p{L}\p{M}\p{N}_-]*)"#
    )
    // A fence opened with ``` or ~~~ runs to the same marker (or the end of the text).
    private static let fencedCode = try! NSRegularExpression(pattern: "(```|~~~)[\\s\\S]*?(\\1|$)")
    private static let inlineCode = try! NSRegularExpression(pattern: "`[^`\\n]*`")

    /// Unique tags in order of first appearance.
    static func parse(_ text: String) -> [ParsedTag] {
        // NFC first, so "café" typed precomposed or decomposed is one tag.
        let source = stripCode(text.precomposedStringWithCanonicalMapping)
        let ns = source as NSString
        var seen = Set<String>()
        var result: [ParsedTag] = []
        for match in tagRegex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            var display = ns.substring(with: match.range(at: 1))
            // A trailing hyphen is punctuation ("#swift-"), not part of the tag.
            while display.hasSuffix("-") { display.removeLast() }
            guard display.contains(where: \.isLetter) else { continue }
            let key = display.lowercased()
            if seen.insert(key).inserted {
                result.append(ParsedTag(key: key, display: display))
            }
        }
        return result
    }

    /// True when a line is nothing but hashtags (used to keep tag lines out of previews).
    static func isOnlyTags(_ line: String) -> Bool {
        let words = line.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return false }
        return words.allSatisfy { word in
            word.hasPrefix("#") && word.count > 1 && !parse(String(word)).isEmpty
        }
    }

    /// Replaces code spans and fenced blocks with spaces so their contents are never tags.
    static func stripCode(_ text: String) -> String {
        var s = text
        for regex in [fencedCode, inlineCode] {
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
        }
        return s
    }
}
