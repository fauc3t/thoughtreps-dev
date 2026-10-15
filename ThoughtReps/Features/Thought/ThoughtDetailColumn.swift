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
/// while shown turns into a placeholder instead of a dead model. Pushed on a stack (no `ThoughtSelection`), an
/// opened thought that disappears pops itself.
struct ThoughtDetailLoader: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThoughtSelection.self) private var selection: ThoughtSelection?
    @Query private var matches: [Thought]
    private let openKind: OpenKind

    init(modelID: PersistentIdentifier, openKind: OpenKind = .open) {
        self.openKind = openKind
        var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { $0.persistentModelID == modelID })
        descriptor.fetchLimit = 1
        _matches = Query(descriptor)
    }

    @State private var isShown = false

    var body: some View {
        Group {
            if let thought = matches.first {
                ThoughtDetailView(thought: thought, openKind: openKind)
            } else if openKind == .visit {
                ContentUnavailableView {
                    Label("This thought was deleted", systemImage: "trash")
                        .font(.archivo(22, weight: .bold, relativeTo: .title2))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.paper)
            } else if selection == nil {
                Color.paper
            } else {
                ThoughtPlaceholder()
            }
        }
        .onAppear {
            isShown = true
            // Deleted while a pushed screen covered it: pop when it comes back. A self-delete only happens after the pop.
            if matches.isEmpty, openKind == .open, selection == nil { dismiss() }
        }
        .onDisappear { isShown = false }
        .onChange(of: matches.isEmpty) { _, gone in
            // Only while on screen: a thought deleted from its own screen is removed after the pop has finished.
            if gone, isShown, openKind == .open, selection == nil { dismiss() }
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
