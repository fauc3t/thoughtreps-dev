import SwiftUI
import SwiftData

/// The split view's detail column: the selected thought, or a placeholder. Nothing is ever selected on
/// its own, because opening a thought counts as a view.
struct ThoughtDetailColumn: View {
    @Environment(ThoughtSelection.self) private var selection: ThoughtSelection?

    var body: some View {
        NavigationStack {
            if let pick = selection?.current {
                SelectedThoughtDetail(modelID: pick.modelID)
                    .id(pick.modelID)
            } else {
                ThoughtPlaceholder()
            }
        }
    }
}

/// Resolves the selection with a primary-key query rather than a model reference, so a thought that is
/// deleted while selected turns into the placeholder instead of a dead model.
private struct SelectedThoughtDetail: View {
    @Query private var matches: [Thought]

    init(modelID: PersistentIdentifier) {
        var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { $0.persistentModelID == modelID })
        descriptor.fetchLimit = 1
        _matches = Query(descriptor)
    }

    var body: some View {
        if let thought = matches.first {
            ThoughtDetailView(thought: thought)
        } else {
            ThoughtPlaceholder()
        }
    }
}

private struct ThoughtPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("Select a thought", systemImage: "text.alignleft")
                .font(.archivo(22, weight: .bold, relativeTo: .title2))
        } description: {
            Text("Pick one from the list to read it.")
                .font(.mono(13, relativeTo: .footnote))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
    }
}
