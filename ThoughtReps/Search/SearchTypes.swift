import Foundation

/// Which thoughts a search covers.
enum SearchScope: Sendable, Equatable {
    /// Everything not archived: due, waiting and pinned thoughts.
    case active
    case archived
    case all
}

/// The part of a thought a result's snippet comes from.
enum SearchField: Sendable, Equatable {
    case body
    /// Text of a markdown block (blurred or not). It is shown in snippets as written.
    case blockText
    case blockTitle
    case tag
}

struct SearchResult: Identifiable, Sendable, Equatable {
    /// The thought's id; fetch the thought from SwiftData to display it.
    let id: UUID
    let isArchived: Bool
    let matchedField: SearchField
    /// Single line, matches wrapped in `SearchSnippet.matchStart` / `matchEnd`. Use `attributedSnippet` to show it.
    let snippet: String
    /// The body snippet with its line breaks, set when `matchedField` is `.body`; `showing(title:)` uses it.
    var bodySnippet: String?
    /// A match in another field, shown instead of a body snippet that only matched the title.
    var otherMatch: Other?

    struct Other: Sendable, Equatable {
        let field: SearchField
        let snippet: String
    }

    /// The result as the card for a thought titled `title` should show it: a body snippet drops the title line
    /// the card already shows, and a body match that was only in the title gives way to another matching field.
    func showing(title: String) -> SearchResult {
        guard matchedField == .body, let bodySnippet else { return self }
        let text = SearchSnippet.droppingTitleLine(from: bodySnippet, title: title)
        if !text.contains(SearchSnippet.matchStart), let other = otherMatch {
            return SearchResult(id: id, isArchived: isArchived, matchedField: other.field, snippet: other.snippet)
        }
        return SearchResult(id: id, isArchived: isArchived, matchedField: .body, snippet: SearchSnippet.singleLine(text), bodySnippet: bodySnippet)
    }

    /// The snippet with matches in bold.
    var attributedSnippet: AttributedString { SearchSnippet.attributed(snippet) }
}

enum SearchSnippet {
    /// Private-use characters that mark a match, so they can't clash with real text (the index
    /// strips them from what it stores).
    static let matchStart: Character = "\u{E000}"
    static let matchEnd: Character = "\u{E001}"

    /// `snippet` with each marked match in bold and the markers removed.
    static func attributed(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var bold = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
            run = ""
        }
        for character in snippet {
            if character == matchStart {
                flush()
                bold = true
            } else if character == matchEnd {
                flush()
                bold = false
            } else {
                run.append(character)
            }
        }
        flush()
        return result
    }

    /// `snippet` without its first line when that line is `title`, the card's title, and the window reaches the top (no leading "…").
    /// Keeps the snippet whole when nothing else is left.
    static func droppingTitleLine(from snippet: String, title: String) -> String {
        guard !snippet.hasPrefix("…"), let newline = snippet.firstIndex(where: \.isNewline) else { return snippet }
        let first = snippet[..<newline]
        guard plain(String(first)).trimmingCharacters(in: .whitespaces) == title else { return snippet }
        var rest = String(snippet[snippet.index(after: newline)...])
        guard !plain(rest).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return snippet }
        if first.filter({ $0 == matchStart }).count > first.filter({ $0 == matchEnd }).count {
            rest = String(matchStart) + rest
        }
        return rest
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// The snippet as plain text, markers removed.
    static func plain(_ snippet: String) -> String {
        snippet.filter { $0 != matchStart && $0 != matchEnd }
    }
}
