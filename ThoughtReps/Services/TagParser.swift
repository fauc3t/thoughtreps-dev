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

    /// One tag occurrence: its range in the matched text, covering `#` and the tag
    /// without trailing hyphens.
    struct Match {
        let range: NSRange
        let tag: ParsedTag
    }

    /// Unique tags in order of first appearance.
    static func parse(_ text: String) -> [ParsedTag] {
        var seen = Set<String>()
        var result: [ParsedTag] = []
        for match in matches(in: normalized(text)) where seen.insert(match.tag.key).inserted {
            result.append(match.tag)
        }
        return result
    }

    /// Unique tags across several texts in order of first appearance. Each text is parsed on its own,
    /// so an unclosed code fence in one can't hide tags in the next.
    static func parse(all texts: [String]) -> [ParsedTag] {
        var seen = Set<String>()
        return texts.flatMap(parse).filter { seen.insert($0.key).inserted }
    }

    /// NFC first, so "café" typed precomposed or decomposed is one tag.
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    /// Every tag occurrence in order, with ranges into `source` (which should be NFC-normalized).
    static func matches(in source: String) -> [Match] {
        let stripped = stripCode(source)
        let ns = stripped as NSString
        var result: [Match] = []
        for match in tagRegex.matches(in: stripped, range: NSRange(location: 0, length: ns.length)) {
            var display = ns.substring(with: match.range(at: 1))
            // A trailing hyphen is punctuation ("#swift-"), not part of the tag.
            while display.hasSuffix("-") { display.removeLast() }
            guard display.contains(where: \.isLetter) else { continue }
            let range = NSRange(location: match.range.location, length: 1 + (display as NSString).length)
            result.append(Match(range: range, tag: ParsedTag(key: display.lowercased(), display: display)))
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

    /// Replaces code spans and fenced blocks with spaces of the same UTF-16 length, so contents
    /// are never tags and offsets into the result still match the original text.
    static func stripCode(_ text: String) -> String {
        let s = NSMutableString(string: text)
        for regex in [fencedCode, inlineCode] {
            let matches = regex.matches(in: s as String, range: NSRange(location: 0, length: s.length))
            for match in matches.reversed() {
                s.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
            }
        }
        return s as String
    }

    // These mirror `tagRegex` scalar by scalar (\p{L}, \p{M}, \p{N}); keep them in sync.

    /// Characters that can continue a tag: letters, combining marks, digits, `_` and `-`.
    static func isTagCharacter(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { $0 == "_" || $0 == "-" || isLetter($0) || isNumber($0) || isMark($0) }
    }

    /// Characters a tag may start with (not `-` or a combining mark).
    static func isTagStart(_ c: Character) -> Bool {
        guard let first = c.unicodeScalars.first else { return false }
        return first == "_" || isLetter(first) || isNumber(first)
    }

    /// Characters that make a following `#` something other than a tag (`C#`, `/#x`, `&#39;`).
    static func blocksTagStart(_ c: Character) -> Bool {
        guard let last = c.unicodeScalars.last else { return false }
        return last == "_" || last == "#" || last == "/" || last == "&" || isLetter(last) || isNumber(last)
    }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    private static func isNumber(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    private static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }
}
