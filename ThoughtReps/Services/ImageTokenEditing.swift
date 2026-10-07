import Foundation

/// Text edits the editor makes when an image is added to or removed from a thought's body.
extension ImageToken {
    private static let anyToken = try! NSRegularExpression(
        pattern: #"!\[([^\]\n]*)\]\(img:([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\)"#
    )

    /// Ids of the images referenced in `body`, each once, in text order.
    static func uniqueReferences(in body: String) -> [UUID] {
        var seen = Set<UUID>()
        return references(in: body).filter { seen.insert($0).inserted }
    }

    /// Every token in `text` with its range and image id, in text order. Unlike `references`,
    /// this does not skip code; callers that care mask it first. It finds each `](img:` and looks
    /// back for the `![` on its line, rather than trying a regex at every `![`, so a long line
    /// of unmatched `![` stays linear.
    static func matches(in text: String) -> [(range: NSRange, id: UUID)] {
        let units = Array(text.utf16)
        let marker = Array("](img:".utf16)
        let newline: UInt16 = 0x0A, close: UInt16 = 0x5D, open: UInt16 = 0x5B, bang: UInt16 = 0x21, paren: UInt16 = 0x29
        var result: [(range: NSRange, id: UUID)] = []
        var floor = 0
        var p = 0
        while p + marker.count + 37 <= units.count {
            let idStart = p + marker.count
            guard units[p...].starts(with: marker), units[idStart + 36] == paren,
                  let id = UUID(uuidString: String(decoding: units[idStart..<(idStart + 36)], as: UTF16.self))
            else { p += 1; continue }
            var start: Int?
            var i = p - 1
            while i >= floor, units[i] != newline, units[i] != close {
                if units[i] == open, i > floor, units[i - 1] == bang { start = i - 1 }
                i -= 1
            }
            guard let start else { p += 1; continue }
            let end = idStart + 37
            result.append((NSRange(location: start, length: end - start), id))
            floor = end
            p = end
        }
        return result
    }

    /// Alt text of each referenced image (the first non-empty one wins). Tokens in code are ignored.
    static func altTexts(in body: String) -> [UUID: String] {
        let stripped = TagParser.stripCode(body) as NSString
        var result: [UUID: String] = [:]
        for match in anyToken.matches(in: stripped as String, range: NSRange(location: 0, length: stripped.length)) {
            let alt = stripped.substring(with: match.range(at: 1))
            guard !alt.isEmpty, let id = UUID(uuidString: stripped.substring(with: match.range(at: 2))) else { continue }
            if result[id] == nil { result[id] = alt }
        }
        return result
    }

    /// Puts the token for `id` in its own paragraph at `cursor` (blank lines around it, so
    /// consecutive images each render as a block). The returned cursor is after the token's paragraph.
    static func inserting(_ id: UUID, into text: String, at cursor: String.Index) -> (text: String, cursor: String.Index) {
        let before = text[..<cursor]
        let after = text[cursor...]
        let precedingBreaks = before.isEmpty ? 2 : before.reversed().prefix { $0 == "\n" }.count
        let followingBreaks = after.prefix { $0 == "\n" }.count

        let lead = String(repeating: "\n", count: max(0, 2 - precedingBreaks))
        let trail = after.isEmpty ? "\n\n" : String(repeating: "\n", count: max(0, 2 - followingBreaks))
        let insertion = lead + token(for: id) + trail

        var result = text
        result.insert(contentsOf: insertion, at: cursor)
        let offset = text.utf16.distance(from: text.startIndex, to: cursor)
        let cursorOffset = offset + insertion.utf16.count + min(followingBreaks, 2)
        return (result, String.Index(utf16Offset: cursorOffset, in: result))
    }

    /// `text` without any token for `id`, whatever its alt text. Tokens inside code are left alone.
    /// A line left empty by the removal is dropped, along with a blank line it would leave doubled.
    static func removing(_ id: UUID, from text: String) -> String {
        let stripped = TagParser.stripCode(text)
        let matches = anyToken.matches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length))
            .filter { UUID(uuidString: (stripped as NSString).substring(with: $0.range(at: 2))) == id }
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            result.deleteCharacters(in: match.range)
            dropLineIfBlank(in: result, at: match.range.location)
        }
        return result as String
    }

    private static func dropLineIfBlank(in text: NSMutableString, at location: Int) {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        guard text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var removal = line
        if line.upperBound == text.length, line.location > 0 {
            removal = NSRange(location: line.location - 1, length: line.length + 1)
        }
        text.deleteCharacters(in: removal)

        let position = removal.location
        let charBefore = position > 0 ? text.character(at: position - 1) : nil
        let charBeforeThat = position > 1 ? text.character(at: position - 2) : nil
        let newline = unichar(10)
        let previousIsBlank = position == 0 || (charBefore == newline && (position == 1 || charBeforeThat == newline))
        if previousIsBlank, position < text.length, text.character(at: position) == newline {
            text.deleteCharacters(in: NSRange(location: position, length: 1))
        }
    }
}
