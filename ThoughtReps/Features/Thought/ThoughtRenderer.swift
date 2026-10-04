import SwiftUI

/// Renders a thought's Markdown.
///
/// This is a deliberately small built-in renderer (headings, paragraphs, lists, task
/// items, quotes, code blocks, rules, inline styles, tag highlighting) so Milestone 1 has
/// no dependencies. Milestone 1's renderer spike picks MarkdownUI or Textual; only this
/// view changes when that lands.
struct ThoughtRenderer: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlocks.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(Inline.render(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 4 : 0)
        case let .paragraph(text):
            Text(Inline.render(text))
                .font(.body)
        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(for: item, index: index, ordered: ordered)
                        Text(Inline.render(item.text))
                            .strikethrough(item.checked == true, color: .secondary)
                            .foregroundStyle(item.checked == true ? Color.secondary : Color.primary)
                    }
                }
            }
        case let .quote(text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(Inline.render(text))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        case .rule:
            Divider()
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownBlock.ListItem, index: Int, ordered: Bool) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
        } else if ordered {
            Text("\(index + 1).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("•")
                .foregroundStyle(.secondary)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        case 3: .title3.weight(.semibold)
        default: .headline
        }
    }
}

/// Inline Markdown (bold, italic, code, links) plus `#tag` highlighting.
enum Inline {
    static func render(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)

        for tag in TagParser.parse(text) {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let range = attributed[searchStart...].range(of: "#\(tag.display)", options: .caseInsensitive) {
                // Skip prefixes of longer tags (#swift inside #swiftui).
                let next = range.upperBound < attributed.endIndex ? attributed.characters[range.upperBound] : " "
                if !(next.isLetter || next.isNumber || next == "_" || next == "-") {
                    attributed[range].swiftUI.foregroundColor = .accentColor
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}

/// Block-level structure of a Markdown string.
enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        var text: String
        /// `nil` for a plain item, `true`/`false` for a task item.
        var checked: Bool?
    }

    case heading(level: Int, text: String)
    case paragraph(String)
    case list(items: [ListItem], ordered: Bool)
    case quote(String)
    case code(String)
    case rule
}

enum MarkdownBlocks {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var listItems: [MarkdownBlock.ListItem] = []
        var listOrdered = false
        var code: [String]? = nil

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        func flushList() {
            if !listItems.isEmpty { blocks.append(.list(items: listItems, ordered: listOrdered)) }
            listItems = []
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushList()
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if code != nil {
                if line.hasPrefix("```") {
                    blocks.append(.code((code ?? []).joined(separator: "\n")))
                    code = nil
                } else {
                    code?.append(raw)
                }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                code = []
                continue
            }
            if line.isEmpty {
                flushAll()
                continue
            }
            if let heading = heading(line) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }
            if let parsed = listItem(line) {
                let (item, ordered) = parsed
                flushParagraph()
                flushQuote()
                if !listItems.isEmpty && ordered != listOrdered { flushList() }
                listOrdered = ordered
                listItems.append(item)
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushList()
            flushQuote()
            paragraph.append(line)
        }

        if let code {
            blocks.append(.code(code.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (MarkdownBlock.ListItem, Bool)? {
        var text: Substring
        var ordered = false
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            text = line.dropFirst(2)
        } else {
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            let after = line.dropFirst(digits.count)
            guard !digits.isEmpty, let mark = after.first, mark == "." || mark == ")",
                  after.dropFirst().first == " " else { return nil }
            text = after.dropFirst(2)
            ordered = true
        }
        var checked: Bool? = nil
        let lower = text.lowercased()
        if lower.hasPrefix("[ ] ") || lower.hasPrefix("[x] ") {
            checked = lower.hasPrefix("[x]")
            text = text.dropFirst(4)
        }
        return (MarkdownBlock.ListItem(text: String(text), checked: checked), ordered)
    }
}
