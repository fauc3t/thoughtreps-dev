import SwiftUI

/// What a link card shows, decided from the target alone. A target that is gone, or is being deleted,
/// reads as deleted so the card never renders a dead model.
struct LinkedThoughtCardModel: Equatable {
    enum State: Equatable {
        case open, archived, deleted
    }

    static let deletedText = "This thought was deleted"

    let state: State
    let title: String
    let preview: String

    init(target: Thought?) {
        guard let target, target.modelContext != nil, !target.isDeleted else {
            state = .deleted
            title = Self.deletedText
            preview = ""
            return
        }
        state = target.isArchived ? .archived : .open
        title = ThoughtTitleSplit.split(target.body)?.title ?? target.title
        preview = target.preview
    }

    var isTappable: Bool { state != .deleted }

    var accessibilityLabel: String {
        switch state {
        case .open: "Linked thought: \(title)"
        case .archived: "Linked thought: \(title), archived"
        case .deleted: "Linked thought: deleted"
        }
    }
}

/// A linked thought as a compact card. Only the target itself shows, never its own blocks or links.
/// Tapping walks to it: a push onto the enclosing stack, which in the split view is the detail column's.
struct LinkedThoughtCard: View {
    let target: Thought?

    var body: some View {
        let model = LinkedThoughtCardModel(target: target)
        if let target, model.isTappable {
            NavigationLink(value: AppRoute.linkedThought(target)) {
                card(model, target: target)
            }
            .buttonStyle(InkPressStyle())
        } else {
            card(model, target: nil)
        }
    }

    private func card(_ model: LinkedThoughtCardModel, target: Thought?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(Color.muted)
                    .accessibilityHidden(true)
                Text(model.title)
                    .font(model.state == .deleted ? .mono(13, relativeTo: .footnote) : .archivo(15))
                    .foregroundStyle(model.state == .deleted ? Color.muted : Color.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.state == .archived {
                    InkBadge(text: "Archived", style: .plain)
                }
            }
            if !model.preview.isEmpty {
                Text(model.preview)
                    .thoughtTextFont(.footnote, size: 13)
                    .foregroundStyle(Color.muted)
                    .lineLimit(2)
            }
            if let target, model.state != .deleted, !target.sortedTags.isEmpty {
                TagChips(tags: target.sortedTags, linked: false)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(model.state == .open ? 1 : 0.6)
        .inkCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(model.preview)
    }
}

/// The thoughts that link to this one, under the thought's own content.
struct LinkedFromSection: View {
    let thoughts: [Thought]
    let total: Int

    var body: some View {
        if !thoughts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Linked from")
                    .inkSectionHeader()
                    .accessibilityAddTraits(.isHeader)
                ForEach(thoughts) { LinkedThoughtCard(target: $0) }
                if total > thoughts.count {
                    Text("and \(total - thoughts.count) more")
                        .font(.mono(12, relativeTo: .footnote))
                        .foregroundStyle(Color.muted)
                }
            }
        }
    }
}
