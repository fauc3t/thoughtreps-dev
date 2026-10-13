import SwiftUI
import SwiftData

/// The split view's detail column: the selected thought, or a placeholder. Nothing is ever selected on
/// its own, because opening a thought counts as a view.
struct ThoughtDetailColumn: View {
    @Environment(ThoughtSelection.self) private var selection: ThoughtSelection?

    private var detailPath: Binding<[AppRoute]> {
        Binding(get: { selection?.detailPath ?? [] }, set: { selection?.detailPath = $0 })
    }

    var body: some View {
        NavigationStack(path: detailPath) {
            Group {
                if let pick = selection?.current {
                    ThoughtDetailLoader(modelID: pick.modelID)
                        .id(pick.modelID)
                } else {
                    ThoughtPlaceholder()
                }
            }
            .thoughtDestinations()
        }
    }
}

/// Resolves a thought with a primary-key query rather than a model reference, so one that is deleted
/// while shown turns into a placeholder instead of a dead model.
struct ThoughtDetailLoader: View {
    @Query private var matches: [Thought]
    private let openKind: OpenKind

    init(modelID: PersistentIdentifier, openKind: OpenKind = .open) {
        self.openKind = openKind
        var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { $0.persistentModelID == modelID })
        descriptor.fetchLimit = 1
        _matches = Query(descriptor)
    }

    var body: some View {
        if let thought = matches.first {
            ThoughtDetailView(thought: thought, openKind: openKind)
        } else if openKind == .visit {
            ContentUnavailableView {
                Label("This thought was deleted", systemImage: "trash")
                    .font(.archivo(22, weight: .bold, relativeTo: .title2))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.paper)
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
