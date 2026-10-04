import SwiftUI

/// Renders any attached block by kind. New kinds add a case here.
struct BlockView: View {
    let block: Block

    var body: some View {
        switch block.kind {
        case .blurred:
            BlurredBlockView(title: block.title, content: block.content)
        }
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
