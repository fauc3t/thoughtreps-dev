import Foundation

/// Splits a thought's body into the title shown in Archivo and the Markdown below it.
enum ThoughtTitleSplit {
    struct Parts: Equatable {
        let title: String
        let rest: String
    }

    /// Nil when the first line isn't a plain paragraph or heading (list item, code fence, table,
    /// image, rule, raw HTML), so the body then renders whole and unchanged.
    static func split(_ body: String) -> Parts? {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        guard isPlain(first) else { return nil }
        let title = MarkdownText.plain(first)
        guard !title.isEmpty else { return nil }
        return Parts(title: title, rest: lines[(index + 1)...].joined(separator: "\n"))
    }

    private static func isPlain(_ line: String) -> Bool {
        let blocked = ["```", "~~~", "|", "!", "<", ">", "- ", "* ", "+ ", "---", "***", "___"]
        if blocked.contains(where: line.hasPrefix) { return false }
        let digits = line.prefix { $0.isNumber }
        return !(!digits.isEmpty && line.dropFirst(digits.count).hasPrefix("."))
    }
}
