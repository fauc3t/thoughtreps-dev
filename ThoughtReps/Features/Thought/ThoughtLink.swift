import SwiftUI

/// A row that opens a thought: selects it in the split view's detail column, or pushes it onto the
/// enclosing navigation stack when there is no split view.
struct ThoughtLink<Label: View>: View {
    let thought: Thought
    @ViewBuilder let label: Label

    @Environment(ThoughtSelection.self) private var selection: ThoughtSelection?

    var body: some View {
        if let selection {
            Button {
                selection.select(thought)
            } label: {
                label.overlay {
                    if selection.isSelected(thought) {
                        RoundedRectangle(cornerRadius: ThemeManager.shared.current.card.cornerRadius)
                            .strokeBorder(Color.ink, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
            }
            .accessibilityAddTraits(selection.isSelected(thought) ? .isSelected : [])
        } else {
            NavigationLink(value: thought) { label }
        }
    }
}
