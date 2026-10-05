import Foundation

/// What the index stores for one thought: plain text per field, plus the two values that decide
/// whether the stored row is current.
///
/// `updatedAt` plus `isArchived` is the reconciliation fingerprint. Every write that changes
/// indexed text bumps `updatedAt` (create, update, import; tags only change with the body), but
/// archive and restore don't, so the archive flag is part of the fingerprint.
struct SearchDocument: Sendable, Equatable {
    var id: UUID
    var updatedAt: Date
    var isArchived: Bool
    var body: String
    /// Contents of the blurred blocks.
    var blocks: String
    /// Titles of all blocks (galleries mostly).
    var titles: String
    var tags: String

    init(id: UUID, updatedAt: Date, isArchived: Bool, body: String, blocks: String = "", titles: String = "", tags: String = "") {
        self.id = id
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.body = Self.clean(body)
        self.blocks = Self.clean(blocks)
        self.titles = Self.clean(titles)
        self.tags = Self.clean(tags)
    }

    /// Snapshots the thought's current in-memory state. Call it where the thought lives, then hand
    /// the value to the index.
    init(_ thought: Thought) {
        let blocks = thought.sortedBlocks
        self.init(
            id: thought.id,
            updatedAt: thought.updatedAt,
            isArchived: thought.isArchived,
            body: SearchText.plain(thought.body),
            blocks: blocks.filter { $0.kind == .blurred }.map { SearchText.plain($0.content) }.filter { !$0.isEmpty }.joined(separator: "\n"),
            titles: blocks.compactMap(\.title).filter { !$0.isEmpty }.joined(separator: "\n"),
            tags: (thought.tags ?? []).map(\.name).sorted().joined(separator: " ")
        )
    }

    private static func clean(_ text: String) -> String {
        text.filter { $0 != SearchSnippet.matchStart && $0 != SearchSnippet.matchEnd }
    }
}

enum SearchText {
    /// Markdown reduced to the words a person sees: image tokens, list and heading markers, code
    /// fences and emphasis are gone. Line breaks are kept.
    static func plain(_ markdown: String) -> String {
        ImageToken.removing(from: markdown)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("```") && !$0.hasPrefix("~~~") }
            .map(MarkdownText.plain)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
