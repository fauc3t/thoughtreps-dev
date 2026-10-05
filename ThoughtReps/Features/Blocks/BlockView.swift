import SwiftUI

/// Renders any attached block by kind. New kinds add a case here.
struct BlockView: View {
    let block: Block
    let onOpenImage: (UUID) -> Void

    var body: some View {
        switch block.kind {
        case .blurred:
            BlurredBlockView(title: block.title, content: block.content)
        case .gallery:
            GalleryBlockView(title: block.title, images: block.sortedImages, onOpenImage: onOpenImage)
        }
    }
}

/// An optional title over a horizontally scrolling row of image tiles.
struct GalleryBlockView: View {
    let title: String?
    let images: [ImageAsset]
    let onOpenImage: (UUID) -> Void

    private static let tileHeight: CGFloat = 160

    private var heading: String? {
        guard let title, !title.isEmpty else { return nil }
        return title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading {
                Text(heading)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        Button { onOpenImage(image.id) } label: {
                            DataImage(id: image.id) { image.thumbnailData }
                                .frame(width: tileWidth(image), height: Self.tileHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(heading ?? "Gallery") image \(index + 1) of \(images.count)")
                        .accessibilityHint("Double tap to view full screen")
                    }
                }
            }
        }
    }

    /// Tiles keep their image's aspect ratio, within a sensible width range.
    private func tileWidth(_ image: ImageAsset) -> CGFloat {
        let ratio = CGFloat(max(image.width, 1)) / CGFloat(max(image.height, 1))
        return min(max(Self.tileHeight * ratio, 100), 260)
    }
}

/// Text hidden behind a blur until tapped. Hidden again every time the thought opens.
struct BlurredBlockView: View {
    let title: String?
    let content: String

    @State private var isRevealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title ?? "Hidden")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isRevealed ? "Hide" : "Tap to reveal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Text(content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .blur(radius: isRevealed ? 0 : 8)
                .animation(.easeInOut(duration: 0.2), value: isRevealed)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .onTapGesture { isRevealed.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRevealed ? "\(title ?? "Hidden text"): \(content)" : "\(title ?? "Hidden text"), hidden")
        .accessibilityHint(isRevealed ? "Double tap to hide" : "Double tap to reveal")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    BlurredBlockView(title: "Answer", content: "O(1) on average, because elements are hashed.")
        .padding()
}
