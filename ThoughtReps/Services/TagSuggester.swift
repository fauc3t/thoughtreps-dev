import Foundation

/// Hashtag autocomplete for the editor: finds the `#partial` being typed, ranks existing
/// tags against it and applies a chosen completion. Pure; the view supplies cursor and tags.
enum TagSuggester {
    struct Candidate: Equatable {
        /// Lowercased key, as in `TagParser.ParsedTag`.
        let key: String
        let display: String
        /// Number of thoughts using the tag.
        let count: Int
    }

    /// The `#partial` ending at `cursor`, or nil when the cursor isn't at the end of a tag
    /// being typed. `partial` excludes the `#`; `range` covers both.
    static func activeToken(in text: String, cursor: String.Index) -> (range: Range<String.Index>, partial: String)? {
        guard cursor <= text.endIndex else { return nil }
        let cursorOffset = cursor.utf16Offset(in: text)
        let cursor = String.Index(utf16Offset: cursorOffset, in: text)

        if let next = text[cursor...].first, TagParser.isTagCharacter(next) { return nil }

        var start = cursor
        while start > text.startIndex {
            let previous = text.index(before: start)
            guard TagParser.isTagCharacter(text[previous]) else { break }
            start = previous
        }
        guard start > text.startIndex else { return nil }
        let hash = text.index(before: start)
        guard text[hash] == "#" else { return nil }

        let partial = String(text[start..<cursor])
        if let first = partial.first, !TagParser.isTagStart(first) { return nil }
        if hash > text.startIndex, TagParser.blocksTagStart(text[text.index(before: hash)]) { return nil }

        let masked = TagParser.stripCode(text)
        let hashOffset = hash.utf16Offset(in: text)
        guard masked.utf16[String.Index(utf16Offset: hashOffset, in: masked)] == 0x23 else { return nil }

        return (hash..<cursor, partial)
    }

    /// Candidates matching `partial` (case- and diacritic-insensitive): prefix matches first,
    /// then substring matches, each by use count then name. An empty partial gives the most used.
    static func suggestions(
        for partial: String,
        from candidates: [Candidate],
        excluding: Set<String>,
        limit: Int = 10
    ) -> [Candidate] {
        let needle = fold(partial)
        var prefixMatches: [Candidate] = []
        var substringMatches: [Candidate] = []
        for candidate in candidates where !excluding.contains(candidate.key) {
            let haystack = fold(candidate.display)
            if haystack.hasPrefix(needle) {
                prefixMatches.append(candidate)
            } else if haystack.contains(needle) {
                substringMatches.append(candidate)
            }
        }
        let ordered = { (a: Candidate, b: Candidate) -> Bool in
            if a.count != b.count { return a.count > b.count }
            return a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
        }
        return Array((prefixMatches.sorted(by: ordered) + substringMatches.sorted(by: ordered)).prefix(limit))
    }

    /// Replaces the token with `#display` and a trailing space (reusing existing whitespace
    /// after it); the returned cursor sits after that space.
    static func apply(
        _ candidate: Candidate,
        replacing range: Range<String.Index>,
        in text: String
    ) -> (text: String, cursor: String.Index) {
        let prefix = text[..<range.lowerBound]
        let suffix = text[range.upperBound...]
        let tag = "#" + candidate.display
        var gap = " "
        var result = String(prefix) + tag
        if let next = suffix.first, next.isWhitespace {
            gap = String(next)
            result += suffix
        } else {
            result += " " + suffix
        }
        let cursorOffset = prefix.utf16.count + tag.utf16.count + gap.utf16.count
        return (result, String.Index(utf16Offset: cursorOffset, in: result))
    }

    /// Inserts `#` at `cursor`, preceded by a space unless the text there is empty or ends in whitespace.
    static func insertHash(in text: String, at cursor: String.Index) -> (text: String, cursor: String.Index) {
        let cursorOffset = cursor <= text.endIndex ? cursor.utf16Offset(in: text) : text.utf16.count
        let cursor = String.Index(utf16Offset: cursorOffset, in: text)
        let needsSpace = text[..<cursor].last.map { !$0.isWhitespace } ?? false
        let insertion = needsSpace ? " #" : "#"
        var result = text
        result.insert(contentsOf: insertion, at: cursor)
        return (result, String.Index(utf16Offset: cursorOffset + insertion.utf16.count, in: result))
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
