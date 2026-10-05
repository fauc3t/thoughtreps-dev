import SwiftUI

/// Editing row for one attached block in the editor.
struct BlockDraftEditor: View {
    @Binding var draft: BlockDraft
    /// Images already stored on the thought, for thumbnails of existing gallery images.
    let storedImages: [UUID: ImageAsset]
    /// Called with this block's id when processed images are ready.
    let onAddImages: (UUID, [ImageDraft]) -> Void

    @State private var intake = ImageIntake()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(draft.kind.label, systemImage: draft.kind.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            switch draft.kind {
            case .blurred:
                TextField("Label (optional), e.g. Answer", text: $draft.title)
                    .font(.subheadline.weight(.semibold))
                TextField("Hidden text", text: $draft.content, axis: .vertical)
                    .lineLimit(2...8)
            case .gallery:
                TextField("Title (optional)", text: $draft.title)
                    .font(.subheadline.weight(.semibold))
                gallery
            }
        }
        .padding(.vertical, 4)
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
