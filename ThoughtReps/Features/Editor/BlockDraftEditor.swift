import SwiftUI

/// The choices of the keyboard bar's "Add block" menu, one per `BlockKind`. The list's `AddBlockMenuButton` builds the same
/// choices from `BlockKind.allCases` with `label` and `systemImage`.
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

/// Editing row for one block in the editor. A Markdown block reads as more paragraphs of the body;
/// the other kinds are cards between paragraphs. Label, blur and delete live in a "…" menu.
struct BlockDraftEditor: View {
    static let markdownMinHeight: CGFloat = 30
    /// The width beside a Markdown block's text kept for its "…" button; the body keeps the same, so paragraphs line up.
    static let gutter: CGFloat = 28

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
    /// True while this block was just added: a text block's Markdown field then takes focus.
    /// A card has nothing to focus.
    var wantsFocus = false
    /// Whether taking focus now would not override something the user focused meanwhile.
    var canTakeFocus: () -> Bool = { true }
    /// Called once the focus request is done, so the owner can drop it.
    var onFocusRequestDone: () -> Void = {}
    /// Called with this block's id when its image processing starts or finishes, so the owner can hold Save.
    var onProcessingChange: (UUID, Bool) -> Void = { _, _ in }
    /// The thought a link block points to, or `nil` when it no longer exists. Unused by other kinds.
    var linkTarget: Thought?
    /// This unnamed block's place among those of its kind, so VoiceOver can tell them apart; nil when there is one.
    var ordinal: Int?
    /// A card the next backspace removes, drawn with a highlight.
    var isSelectedCard = false
    /// Removes this block, from the "…" menu.
    var onRemove: () -> Void = {}
    /// Asks the owner to edit this block's label (a gallery's title).
    var onEditTitle: () -> Void = {}
    /// Called when backspace is pressed at the start of this block's text; nil leaves backspace alone.
    var onBackspaceAtStart: (() -> Void)?
    /// Called with this block's id when processed images are ready.
    let onAddImages: (UUID, [ImageDraft]) -> Void

    @State private var intake = ImageIntake()
    @State private var contentHeight = BlockDraftEditor.markdownMinHeight + 8

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
        Group {
            if draft.kind == .markdown {
                markdownRow
            } else {
                card
            }
        }
        .task(id: wantsFocus) { await focusWhenReady() }
    }

    private var markdownRow: some View {
        HStack(alignment: .top, spacing: 0) {
            markdown
                .padding(.horizontal, draft.isBlurred ? 8 : 0)
                .background(RoundedRectangle(cornerRadius: 8).fill(draft.isBlurred ? Color.accentColor.opacity(0.12) : .clear))
                .padding(.horizontal, draft.isBlurred ? -8 : 0)
            optionsMenu
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if draft.kind == .gallery, !draft.title.isEmpty {
                    Text(draft.title)
                        .font(.subheadline.weight(.semibold))
                }
                switch draft.kind {
                case .gallery: gallery
                case .thoughtLink: link
                case .file: file
                case .markdown: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            optionsMenu
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: isSelectedCard ? 2 : 0))
        .padding(.vertical, 6)
        .accessibilityAddTraits(isSelectedCard ? .isSelected : [])
    }

    private var optionsMenu: some View {
        Menu {
            switch draft.kind {
            case .markdown:
                Button(action: onEditTitle) {
                    Label(draft.title.isEmpty ? "Add label" : "Edit label", systemImage: "pencil")
                }
                Toggle("Blur until tapped", isOn: $draft.isBlurred)
            case .gallery:
                Button(action: onEditTitle) {
                    Label(draft.title.isEmpty ? "Add title" : "Edit title", systemImage: "pencil")
                }
            case .thoughtLink, .file:
                EmptyView()
            }
            Button(role: .destructive, action: onRemove) {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.gutter, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(optionsLabel)
    }

    private var optionsLabel: String {
        switch draft.kind {
        case .markdown: "\(markdownName) options"
        case .gallery: draft.title.isEmpty ? "\(numbered("Gallery")) options" : "Options for \(draft.title)"
        case .thoughtLink: "\(numbered("Link")) options"
        case .file: draft.file.map { "Options for \($0.filename)" } ?? "File options"
        }
    }

    private var markdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !draft.title.isEmpty {
                Text(draft.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
            }
            MarkdownTextView(
                text: $draft.content,
                selection: $selection,
                isFocused: isFocused,
                accessibilityLabel: markdownAccessibilityLabel,
                imageData: imageData,
                accessory: accessory,
                undoResetToken: 0,
                height: $contentHeight,
                minHeight: Self.markdownMinHeight,
                placeholder: "Markdown text",
                onBackspaceAtStart: onBackspaceAtStart
            )
            .frame(height: contentHeight)
            let thumbnails = inlineThumbnails(in: draft.content, drafts: inlineDrafts, stored: storedImages)
            if !thumbnails.isEmpty {
                InlineImageStrip(thumbnails: thumbnails) { id in
                    draft.content = ImageToken.removing(id, from: draft.content)
                    selection = nil
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var markdownAccessibilityLabel: String {
        draft.isBlurred ? "\(markdownName), blurred until tapped" : markdownName
    }

    private var markdownName: String {
        draft.title.isEmpty ? numbered("Text block", fallback: 1) : draft.title
    }

    private func numbered(_ name: String, fallback: Int? = nil) -> String {
        (ordinal ?? fallback).map { "\(name) \($0)" } ?? name
    }

    private var link: some View {
        let model = LinkedThoughtCardModel(target: linkTarget)
        let tags = model.state == .deleted ? [] : (linkTarget?.sortedTags ?? [])
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(model.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.state == .deleted ? .secondary : .primary)
                    .lineLimit(1)
                if model.state == .archived {
                    Text("Archived").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.preview.isEmpty {
                Text(model.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            if !tags.isEmpty {
                Text(tags.map { "#\($0.displayName)" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(model.preview)
    }

    @ViewBuilder
    private var file: some View {
        if let file = draft.file {
            let model = FileCardModel(file)
            FileCardContent(model: model)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.accessibilityLabel)
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
        .onChange(of: intake.isProcessing) { _, processing in
            onProcessingChange(draft.id, processing)
        }
    }
}
