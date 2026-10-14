import Foundation

/// The editor's content as one flowing document: the body, then the blocks in order. Pure edits for
/// adding a block after a text or card, and for joining texts with backspace.
struct EditorDocument: Equatable {
    var body: String
    var drafts: [BlockDraft]

    /// A place in one Markdown field, as a UTF-16 offset.
    struct Position: Equatable {
        var field: EditorField
        var offset: Int
    }

    /// What a new block goes after.
    enum Anchor: Equatable {
        case field(EditorField)
        case card(UUID)
    }

    enum Backspace: Equatable {
        case none
        /// The card before the block should be highlighted; a second backspace removes it.
        case selectCard(UUID)
        /// Something was removed or merged; the cursor belongs here.
        case moved(Position)
    }

    private static let paragraphBreak = "\n\n"

    // MARK: Fields

    private func text(of field: EditorField) -> String? {
        switch field {
        case .body:
            return body
        case let .block(id):
            guard let draft = drafts.first(where: { $0.id == id }), draft.kind == .markdown else { return nil }
            return draft.content
        }
    }

    private mutating func setText(_ text: String, of field: EditorField) {
        switch field {
        case .body:
            body = text
        case let .block(id):
            if let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index].content = text }
        }
    }

    /// The label and blur of a field; the body has neither.
    private func label(of field: EditorField) -> (title: String, isBlurred: Bool) {
        guard case let .block(id) = field, let draft = drafts.first(where: { $0.id == id }) else { return ("", false) }
        return (draft.title, draft.isBlurred)
    }

    /// Two texts join only when neither has a label and both are blurred or both are not.
    private func canJoin(_ first: EditorField, _ second: EditorField) -> Bool {
        let a = label(of: first)
        let b = label(of: second)
        return a.title.isEmpty && b.title.isEmpty && a.isBlurred == b.isBlurred
    }

    /// The field of the text just before `drafts[index]`, or nil when a card sits there.
    private func markdownField(before index: Int) -> EditorField? {
        if index == 0 { return .body }
        let previous = drafts[index - 1]
        return previous.kind == .markdown ? .block(previous.id) : nil
    }

    /// Moves `drafts[index]`'s text to the end of `field`, joined by a blank line, and removes the block.
    private mutating func merge(blockAt index: Int, into field: EditorField) -> Position {
        let first = text(of: field) ?? ""
        let second = drafts[index].content
        let separator = first.isEmpty || second.isEmpty ? "" : Self.paragraphBreak
        setText(first + separator + second, of: field)
        drafts.remove(at: index)
        return Position(field: field, offset: first.utf16.count + separator.utf16.count)
    }

    // MARK: Insert

    /// Inserts `blocks` directly after `anchor` (the whole text or card, never inside it), or at the end
    /// without one. Returns the field to type in next: the new Markdown block, otherwise the Markdown
    /// block that follows the inserted ones, otherwise a new empty one added after them. The exception is
    /// an empty body, which keeps the focus rather than gaining a block below.
    @discardableResult
    mutating func insert(_ blocks: [BlockDraft], after anchor: Anchor?) -> EditorField {
        guard !blocks.isEmpty else {
            if case let .field(field) = anchor { return field }
            return .body
        }
        var index = drafts.count
        switch anchor {
        case .field(.body):
            index = 0
        case let .field(.block(id)), let .card(id):
            if let at = drafts.firstIndex(where: { $0.id == id }) { index = at + 1 }
        case nil:
            break
        }

        if blocks.count == 1, blocks[0].kind == .markdown {
            drafts.insert(blocks[0], at: index)
            return .block(blocks[0].id)
        }

        drafts.insert(contentsOf: blocks, at: index)
        if anchor == .field(.body), body.allSatisfy(\.isWhitespace) { return .body }
        let after = index + blocks.count
        if after < drafts.count, drafts[after].kind == .markdown { return .block(drafts[after].id) }
        let rest = BlockDraft(kind: .markdown)
        drafts.insert(rest, at: after)
        return .block(rest.id)
    }

    // MARK: Backspace

    /// Backspace with the cursor at the very start of a Markdown block. After a card it highlights the
    /// card, then (when `selectedCard` is it) removes it; after a text it joins the block into that text.
    mutating func backspaceAtStart(of id: UUID, selectedCard: UUID?) -> Backspace {
        guard let index = drafts.firstIndex(where: { $0.id == id }), drafts[index].kind == .markdown else { return .none }
        guard let previous = markdownField(before: index) else {
            let card = drafts[index - 1].id
            guard selectedCard == card else { return .selectCard(card) }
            drafts.remove(at: index - 1)
            return .moved(Position(field: .block(id), offset: 0))
        }
        if drafts[index].content.isEmpty {
            drafts.remove(at: index)
            return .moved(Position(field: previous, offset: (text(of: previous) ?? "").utf16.count))
        }
        guard canJoin(previous, .block(id)) else { return .none }
        return .moved(merge(blockAt: index, into: previous))
    }
}
