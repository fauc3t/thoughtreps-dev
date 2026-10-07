import SwiftUI

/// Renders any attached block by kind. New kinds add a case here.
struct BlockView: View {
    let block: Block
    /// The thought's own images, which inline tokens in a markdown block resolve against.
    let images: [ImageAsset]
    let onOpenImage: (UUID) -> Void

    var body: some View {
        switch block.kind {
        case .markdown:
            MarkdownBlockView(
                title: block.title,
                content: block.content,
                isBlurred: block.isBlurred,
                images: images,
                onOpenImage: onOpenImage
            )
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

/// A Markdown block, rendered like the thought's body under an optional label.
struct MarkdownBlockView: View {
    let title: String?
    let content: String
    let isBlurred: Bool
    let images: [ImageAsset]
    let onOpenImage: (UUID) -> Void

    private var heading: String? {
        guard let title, !title.isEmpty else { return nil }
        return title
    }

    var body: some View {
        if isBlurred {
            BlurredBlockView(title: heading, content: content, images: images, onOpenImage: onOpenImage)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let heading {
                    Text(heading)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                }
                ThoughtRenderer(markdown: content, images: images) { onOpenImage($0) }
            }
        }
    }
}

/// Markdown hidden behind a blur until tapped. Hidden again every time the thought opens.
struct BlurredBlockView: View {
    let title: String?
    let content: String
    var images: [ImageAsset] = []
    var onOpenImage: (UUID) -> Void = { _ in }

    @State private var isRevealed = false

    private var name: String { title ?? "Hidden text" }

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
            ThoughtRenderer(markdown: content, images: images) { onOpenImage($0) }
                .allowsHitTesting(isRevealed)
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
        .hoverEffect(.highlight)
        .onTapGesture { isRevealed.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRevealed ? "\(name): \(Self.spokenText(content))" : "\(name), hidden")
        .accessibilityHint(isRevealed ? "Double tap to hide" : "Double tap to reveal")
        .accessibilityAddTraits(.isButton)
    }
}

extension BlurredBlockView {
    /// The content as plain words, so VoiceOver doesn't read Markdown syntax or image URLs aloud.
    static func spokenText(_ content: String) -> String {
        SearchText.plain(content).replacingOccurrences(of: "\n", with: ". ")
    }
}

#Preview {
    BlurredBlockView(title: "Answer", content: "**O(1)** on average, because elements are hashed.")
        .padding()
}
