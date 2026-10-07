import SwiftUI

/// A Markdown text field in the editor: the thought's body or one block's text.
/// The keyboard toolbar, tag suggestions and image insertion all act on the focused one.
enum EditorField: Hashable {
    case body
    case block(UUID)

    /// Whether `field` is the focused one, as a flag its text view can read and write. Turning it off
    /// clears the focus only if `field` still holds it, so a field that lost focus to another can't clear it.
    static func isFocused(_ focus: Binding<EditorField?>, field: EditorField) -> Binding<Bool> {
        Binding(
            get: { focus.wrappedValue == field },
            set: { isOn in
                if isOn {
                    focus.wrappedValue = field
                } else if focus.wrappedValue == field {
                    focus.wrappedValue = nil
                }
            }
        )
    }

    /// `field`, or the body if it is a block that has since been deleted.
    static func resolve(_ field: EditorField, drafts: [BlockDraft]) -> EditorField {
        if case let .block(id) = field, !drafts.contains(where: { $0.id == id }) { return .body }
        return field
    }

    /// Puts the token for each image in `ids` at the cursor of one field, each in its own paragraph.
    static func insertImageTokens(_ ids: [UUID], into text: Binding<String>, selection: Binding<TextSelection?>) {
        for id in ids {
            let current = text.wrappedValue
            var cursor = current.endIndex
            if let selected = selection.wrappedValue, case let .selection(range) = selected.indices,
               range.upperBound <= current.endIndex {
                cursor = range.upperBound
            }
            let inserted = ImageToken.inserting(id, into: current, at: cursor)
            text.wrappedValue = inserted.text
            selection.wrappedValue = TextSelection(insertionPoint: inserted.cursor)
        }
    }

    /// Completes the `#partial` at `range` of one field with a suggested tag.
    static func applyTag(
        _ candidate: TagSuggester.Candidate,
        replacing range: Range<String.Index>,
        in text: Binding<String>,
        selection: Binding<TextSelection?>
    ) {
        let applied = TagSuggester.apply(candidate, replacing: range, in: text.wrappedValue)
        text.wrappedValue = applied.text
        selection.wrappedValue = TextSelection(insertionPoint: applied.cursor)
    }

    /// The index of the single text that changed between two same-length lists, or nil if none or several did.
    static func changedIndex(from old: [String], to new: [String]) -> Int? {
        guard old.count == new.count else { return nil }
        let changed = zip(old, new).enumerated().filter { $0.element.0 != $0.element.1 }
        return changed.count == 1 ? changed[0].offset : nil
    }
}

/// A thumbnail for an inline image whose token is in a text.
typealias InlineThumbnail = (id: UUID, data: @MainActor () -> Data?)

/// Thumbnails for the images whose tokens are in `text`, in text order. Tokens with no known image are skipped.
@MainActor
func inlineThumbnails(in text: String, drafts: [ImageDraft], stored: [UUID: ImageAsset]) -> [InlineThumbnail] {
    guard text.contains("](img:") else { return [] }
    return ImageToken.uniqueReferences(in: text).compactMap { id in
        if let processed = drafts.first(where: { $0.id == id })?.processed {
            return (id, { processed.thumbnailData })
        }
        if let asset = stored[id], asset.isInline {
            return (id, { asset.thumbnailData })
        }
        return nil
    }
}

/// A row of inline image thumbnails, each removable (which deletes its token from the text).
struct InlineImageStrip: View {
    let thumbnails: [InlineThumbnail]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(thumbnails.enumerated()), id: \.element.id) { index, thumbnail in
                    RemovableThumbnail(
                        id: thumbnail.id,
                        index: index + 1,
                        count: thumbnails.count,
                        data: thumbnail.data
                    ) {
                        remove(thumbnail.id)
                    }
                }
            }
        }
    }
}
