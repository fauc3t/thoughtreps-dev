import SwiftUI

/// Caps for wide layouts (iPad). Narrower than the cap, the system's own side margins stay, so iPhone is untouched.
enum ReadableWidth {
    /// Lists, thought text and the editor.
    static let column: CGFloat = 680
    /// The thought's interval bar.
    static let controls: CGFloat = 560

    /// The margin that centers a column of at most `cap` in `width`.
    static func sideMargin(for width: CGFloat, cap: CGFloat = column) -> CGFloat {
        max(0, ((width - cap) / 2).rounded(.down))
    }
}

private struct ReadableContentMargins: ViewModifier {
    let cap: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let margin = ReadableWidth.sideMargin(for: width, cap: cap)
        return content
            .contentMargins(.horizontal, margin > 0 ? margin : nil, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension View {
    /// Centers a scroll view's content in a column of at most `cap`, leaving the scroll indicators at the edge.
    func readableContentMargins(cap: CGFloat = ReadableWidth.column) -> some View {
        modifier(ReadableContentMargins(cap: cap))
    }
}
