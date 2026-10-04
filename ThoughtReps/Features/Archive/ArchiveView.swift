import SwiftUI
import SwiftData

/// Retired thoughts. They never resurface until restored.
struct ArchiveView: View {
    @Environment(\.modelContext) private var context

    @Query(
        filter: #Predicate<Thought> { $0.isArchived == true },
        sort: [SortDescriptor(\Thought.archivedAt, order: .reverse)]
    )
    private var archived: [Thought]

    @State private var search = ""

    private var store: ThoughtStore {
        ThoughtStore(context: context)
    }

    private var visible: [Thought] {
        guard !search.isEmpty else { return archived }
        return archived.filter { $0.body.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(visible) { thought in
            NavigationLink(value: thought) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thought.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let archivedAt = thought.archivedAt {
                        Text("Archived \(archivedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .swipeActions(edge: .leading) {
                Button {
                    store.restore(thought, now: .now)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.accentColor)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    store.delete(thought)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .overlay {
            if visible.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView(
                        "Archive is empty",
                        systemImage: "archivebox",
                        description: Text("Swipe left on a thought to archive it.")
                    )
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        .searchable(text: $search, prompt: "Search archive")
        .navigationTitle("Archive")
    }
}
