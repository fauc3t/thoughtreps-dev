import SwiftUI
import MarkdownUI

/// Renders a thought's Markdown (GitHub flavored) with `#tags` as tappable links.
///
/// MarkdownUI sits behind this view so the library can be swapped without touching callers.
/// Tag links use the `thoughtreps-tag:` scheme; the presenting view handles them via `openURL`.
struct ThoughtRenderer: View {
    let markdown: String
    let images: [ImageAsset]
    let onOpenImage: @MainActor (UUID) -> Void

    @State private var library: ImageLibrary
    @AppStorage(AppSettings.Key.thoughtFont) private var thoughtFont = ThoughtFont.paperMono

    init(markdown: String, images: [ImageAsset] = [], onOpenImage: @escaping @MainActor (UUID) -> Void = { _ in }) {
        self.markdown = markdown
        self.images = images
        self.onOpenImage = onOpenImage
        _library = State(initialValue: ImageLibrary(images: images, markdown: markdown))
    }

    var body: some View {
        let provider = LocalImageProvider(library: library, onOpen: onOpenImage)
        Markdown(TagLinker.link(markdown))
            .markdownTheme(.thoughtReps(font: thoughtFont))
            .markdownImageProvider(provider)
            .markdownInlineImageProvider(provider)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .onChange(of: images.map(\.id)) { library.update(images, markdown: markdown) }
            .onChange(of: markdown) { library.update(images, markdown: markdown) }
    }
}

/// Local-first: only `img:<id>` URLs resolve, against the thought's own images. Any other URL, and
/// any id the thought doesn't have, renders nothing, and nothing is fetched from the network.
struct LocalImageProvider: ImageProvider, InlineImageProvider {
    let library: ImageLibrary
    let onOpen: @MainActor (UUID) -> Void

    func makeImage(url: URL?) -> some View {
        LibraryImage(library: library, id: url.flatMap(ImageToken.id(from:)), onOpen: onOpen)
    }

    /// Images inside a line of text are small: downsampled and drawn at three pixels per point.
    func image(with url: URL, label: String) async throws -> Image {
        guard let id = ImageToken.id(from: url),
              let image = await library.image(for: id, maxPixel: ImageDecoding.inlineMaxPixel),
              let cgImage = image.cgImage
        else { throw URLError(.unsupportedURL) }
        return Image(decorative: cgImage, scale: 3)
    }
}

/// A block-level inline image: fitted to the width, with its aspect ratio reserved before it decodes.
private struct LibraryImage: View {
    let library: ImageLibrary
    let id: UUID?
    let onOpen: @MainActor (UUID) -> Void

    var body: some View {
        if let id, let asset = library.assets[id] {
            Color.clear
                .aspectRatio(CGFloat(max(asset.width, 1)) / CGFloat(max(asset.height, 1)), contentMode: .fit)
                .frame(minWidth: 120, maxWidth: .infinity)
                .overlay {
                    DataImage(id: id, maxPixel: ImageDecoding.bodyMaxPixel, cache: library.cache) { asset.data }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
                .onTapGesture { onOpen(id) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(library.altTexts[id] ?? "Image")
                .accessibilityHint("Double tap to view full screen")
                .accessibilityAddTraits(.isButton)
        }
    }
}


#Preview {
    ScrollView {
        ThoughtRenderer(markdown: """
        # Heading one
        ## Heading two
        ### Heading three

        Some **bold**, *italic*, ~~struck~~ and `inline code` with #swift and #swiftui tags,
        plus a [link](https://example.com).

        > A quoted line about #reading

        - [x] Done task
        - [ ] Open task
        - Plain item
          - Nested item

        1. First
        2. Second

        | Name | Value |
        | --- | --- |
        | Alpha | 1 |
        | Beta | 2 |

        ```swift
        let thought = "resurface me"
        ```

        ---
        """)
        .padding(20)
    }
}
