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

    /// The snippet as plain text, markers removed.
    static func plain(_ snippet: String) -> String {
        snippet.filter { $0 != matchStart && $0 != matchEnd }
    }
}
