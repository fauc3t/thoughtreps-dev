import Foundation
import SwiftData

/// One captured thought: a Markdown body plus the schedule that brings it back.
///
/// Every stored property has a default and every relationship is optional so the
/// store can be switched to CloudKit sync later without a migration.
@Model
final class Thought {
    var id: UUID = UUID()
    var body: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// When the thought next appears on the timeline.
    var nextDueAt: Date = Date.now
    var lastViewedAt: Date? = nil
    var viewCount: Int = 0

    /// Per-thought interval override in days; `nil` means "use the global default".
    var intervalDays: Int? = nil
    /// Raw value of `IntervalMode`. Stored as a string so new modes need no migration.
    var intervalModeRaw: String = IntervalMode.fixed.rawValue

    var isPinned: Bool = false
    var isArchived: Bool = false
    var archivedAt: Date? = nil

    @Relationship(inverse: \Tag.thoughts)
    var tags: [Tag]? = []

    @Relationship(deleteRule: .cascade, inverse: \Block.thought)
    var blocks: [Block]? = []

    @Relationship(deleteRule: .cascade, inverse: \ImageAsset.thought)
    var images: [ImageAsset]? = []

    init(body: String, createdAt: Date = .now, nextDueAt: Date, intervalDays: Int? = nil) {
        self.id = UUID()
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.nextDueAt = nextDueAt
        self.intervalDays = intervalDays
    }
}

extension Thought {
    var intervalMode: IntervalMode {
        get { IntervalMode(rawValue: intervalModeRaw) ?? .fixed }
        set { intervalModeRaw = newValue.rawValue }
    }

    /// The interval actually used for scheduling.
    func effectiveIntervalDays(defaultDays: Int) -> Int {
        max(1, intervalDays ?? defaultDays)
    }

    var sortedTags: [Tag] {
        (tags ?? []).sorted { $0.name < $1.name }
    }

    var isUntagged: Bool {
        (tags ?? []).isEmpty
    }

    var sortedBlocks: [Block] {
        (blocks ?? []).sorted { $0.order < $1.order }
    }

    /// First non-empty line, with leading heading markers removed.
    var title: String {
        let line = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let stripped = MarkdownText.plain(line)
        return stripped.isEmpty ? "Untitled thought" : stripped
    }

    /// The lines after the title, flattened to plain text for list previews.
    var preview: String {
        var lines = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        if !lines.isEmpty { lines.removeFirst() }
        let text = lines
            .filter { !TagParser.isOnlyTags($0) }
            .map { MarkdownText.plain($0) }
            .joined(separator: " ")
        return text
    }
}

/// Small helpers for turning a Markdown line into display text.
enum MarkdownText {
    /// Strips list markers, heading markers (`# ` with a space, never a `#tag`) and inline emphasis.
    static func plain(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "+ ", "> "] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        let hashes = s.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), s.dropFirst(hashes).first == " " {
            s = s.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        }
        if let attributed = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return String(attributed.characters)
        }
        return s
    }
}
