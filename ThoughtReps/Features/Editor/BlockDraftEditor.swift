import SwiftUI

/// The choices of every "Add block" menu, one per `BlockKind`, so the menus can't drift apart.
struct AddBlockMenuItems: View {
    let onAdd: (BlockKind) -> Void

    var body: some View {
        ForEach(BlockKind.allCases) { kind in
            Button {
                onAdd(kind)
            } label: {
                Label(kind.label, systemImage: kind.systemImage)
            }
        }
    }
}

extension Array where Element == BlockDraft {
    /// Appends a new block of `kind` and returns its id.
    @discardableResult
    mutating func addBlock(_ kind: BlockKind) -> UUID {
        let draft = BlockDraft(kind: kind)
        append(draft)
        return draft.id
    }
}

/// Editing row for one attached block in the editor.
struct BlockDraftEditor: View {
    static let markdownMinHeight: CGFloat = 100

    @Binding var draft: BlockDraft
    /// The cursor in this block's Markdown text.
    @Binding var selection: TextSelection?
    /// Whether this block's Markdown field is the focused editor field.
    var isFocused: Binding<Bool>
    /// The keyboard accessory acting on this block's Markdown field.
    let accessory: AnyView
    /// Image bytes for the thumbnails of tokens in this block's text: the thought's own images and new inline images only.
    let imageData: (UUID) -> Data?
    /// Images already stored on the thought, for thumbnails of existing images.
    let storedImages: [UUID: ImageAsset]
    /// New inline images added to the thought, for thumbnails of tokens in this block's text.
    let inlineDrafts: [ImageDraft]
    /// True while this block was just added: a text block's Markdown field then takes focus
    /// (not its optional label). A gallery has nothing to focus.
    var wantsFocus = false
    /// Whether taking focus now would not override something the user focused meanwhile.
    var canTakeFocus: () -> Bool = { true }
    /// Called once the focus request is done, so the owner can drop it.
    var onFocusRequestDone: () -> Void = {}
    /// Called with this block's id when processed images are ready.
    let onAddImages: (UUID, [ImageDraft]) -> Void

    @State private var intake = ImageIntake()
    @State private var contentHeight = BlockDraftEditor.markdownMinHeight

    /// Setting focus as a freshly inserted row appears is unreliable, so it waits for the scroll and tries twice.
    private func focusWhenReady() async {
        guard wantsFocus, draft.kind == .markdown else { return }
        for delay in [350, 250] {
            try? await Task.sleep(for: .milliseconds(delay))
            if Task.isCancelled || !canTakeFocus() { return }
            isFocused.wrappedValue = true
        }
        onFocusRequestDone()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(draft.kind.label, systemImage: draft.kind.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            switch draft.kind {
            case .markdown:
                markdown
            case .gallery:
                TextField("Title (optional)", text: $draft.title)
                    .font(.subheadline.weight(.semibold))
                gallery
            }
        }
        .padding(.vertical, 4)
        .task(id: wantsFocus) { await focusWhenReady() }
    }

    private var markdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Label (optional), e.g. Answer", text: $draft.title)
                .font(.subheadline.weight(.semibold))
            MarkdownTextView(
                text: $draft.content,
                selection: $selection,
                isFocused: isFocused,
                accessibilityLabel: draft.title.isEmpty ? "Text block" : draft.title,
                imageData: imageData,
                accessory: accessory,
                undoResetToken: 0,
                height: $contentHeight,
                minHeight: Self.markdownMinHeight,
                placeholder: "Markdown text"
            )
            .frame(height: contentHeight)
            let thumbnails = inlineThumbnails(in: draft.content, drafts: inlineDrafts, stored: storedImages)
            if !thumbnails.isEmpty {
                InlineImageStrip(thumbnails: thumbnails) { id in
                    draft.content = ImageToken.removing(id, from: draft.content)
                    selection = nil
                }
            }
            Toggle("Blur until tapped", isOn: $draft.isBlurred)
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(draft.images.enumerated()), id: \.element.id) { index, image in
                        RemovableThumbnail(id: image.id, index: index + 1, count: draft.images.count) {
                            image.processed?.thumbnailData ?? storedImages[image.id]?.thumbnailData
                        } remove: {
                            draft.images.removeAll { $0.id == image.id }
                        }
                    }
                    Menu {
                        ImageSourceButtons(intake: intake)
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .frame(width: 72, height: 72)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill)))
                    }
                    .padding(.top, 8)
                    .accessibilityLabel("Add images")
                }
            }
            ImageProcessingIndicator(intake: intake)
            if draft.images.isEmpty {
                Text("Add at least one image, or this gallery won't be saved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .imageIntake(intake) { [blockID = draft.id] added in
            onAddImages(blockID, added)
        }
    }
}
