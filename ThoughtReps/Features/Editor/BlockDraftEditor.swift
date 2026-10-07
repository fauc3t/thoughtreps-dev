import SwiftUI

/// Editing row for one attached block in the editor.
struct BlockDraftEditor: View {
    @Binding var draft: BlockDraft
    /// The cursor in this block's Markdown text.
    @Binding var selection: TextSelection?
    var focus: FocusState<EditorField?>.Binding
    /// Images already stored on the thought, for thumbnails of existing images.
    let storedImages: [UUID: ImageAsset]
    /// New inline images added to the thought, for thumbnails of tokens in this block's text.
    let inlineDrafts: [ImageDraft]
    /// Called with this block's id when processed images are ready.
    let onAddImages: (UUID, [ImageDraft]) -> Void

    @State private var intake = ImageIntake()

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
    }

    private var markdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Label (optional), e.g. Answer", text: $draft.title)
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $draft.content, selection: $selection)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
                .focused(focus, equals: .block(draft.id))
                .accessibilityLabel(draft.title.isEmpty ? "Text block" : draft.title)
                .overlay(alignment: .topLeading) {
                    if draft.content.isEmpty {
                        Text("Markdown text")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
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
