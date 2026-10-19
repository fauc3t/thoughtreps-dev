import SwiftUI

/// A conflict copy on the timeline: its card, with the thought it is a copy of under it as a small card.
/// Tapping opens the resolve sheet rather than the thought, so looking at it never requeues anything.
struct ConflictCopyRow: View {
    let copy: Thought
    /// The original, or nil once it is gone.
    let original: Thought?
    let now: Date

    var body: some View {
        Button {
            AppNavigation.shared.requestResolve(copyID: copy.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ThoughtCard(thought: copy, now: now)
                originalCard
                    .padding(.leading, 16)
            }
        }
        .accessibilityHint("Opens the choices for this copy")
    }

    @ViewBuilder
    private var originalCard: some View {
        if let original {
            let model = LinkedThoughtCardModel(target: original)
            VStack(alignment: .leading, spacing: 2) {
                Text("Original · \(model.title)")
                    .font(.archivo(14))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if !model.preview.isEmpty {
                    Text(model.preview)
                        .thoughtTextFont(.footnote, size: 13)
                        .foregroundStyle(Color.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkCard(filled: true)
        } else {
            Text("Original deleted")
                .font(.mono(12, relativeTo: .footnote))
                .foregroundStyle(Color.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .inkCard(filled: true)
        }
    }
}
