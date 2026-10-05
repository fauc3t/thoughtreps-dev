import SwiftUI
import MarkdownUI

/// Renders a thought's Markdown (GitHub flavored) with `#tags` as tappable links.
///
/// MarkdownUI sits behind this view so the library can be swapped without touching callers.
/// Tag links use the `thoughtreps-tag:` scheme; the presenting view handles them via `openURL`.
struct ThoughtRenderer: View {
    let markdown: String

    var body: some View {
        Markdown(TagLinker.link(markdown))
            .markdownTheme(.thoughtReps)
            .markdownImageProvider(LocalImageProvider())
            .markdownInlineImageProvider(LocalImageProvider())
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}

/// Local-first: never fetches an image from the network. Images render as nothing for now;
/// Milestone 3 adds the `img:<id>` case, resolved from `Images/<thoughtID>/`.
private struct LocalImageProvider: ImageProvider, InlineImageProvider {
    func makeImage(url: URL?) -> some View {
        EmptyView()
    }

    func image(with url: URL, label: String) async throws -> Image {
        throw URLError(.unsupportedURL)
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
