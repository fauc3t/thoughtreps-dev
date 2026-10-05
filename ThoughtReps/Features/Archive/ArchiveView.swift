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
    @State private var model: SearchModel?
    @State private var now = Date.now

    private var store: ThoughtStore {
        ThoughtStore(context: context)
    }

    private var isSearching: Bool {
        SearchModel.isSearchable(search)
    }

    var body: some View {
        Group {
            if isSearching, let model {
                searchResults(model)
            } else {
                archiveList
            }
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        .searchable(text: $search, prompt: "Search archive")
        .navigationTitle("Archive")
        .onAppear {
            now = .now
            if model == nil { model = SearchModel(scope: .archived, context: context) }
            model?.pruneRows()
        }
        .task(id: search) { await model?.search(search) }
    }

    private func searchResults(_ model: SearchModel) -> some View {
        List(model.liveRows) { row in
            SearchResultLink(row: row, model: model, now: now)
            .swipeActions(edge: .leading) {
                Button {
                    model.remove(id: row.id)
                    store.restore(row.thought, now: .now)
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .tint(.accentColor)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    model.remove(id: row.id)
                    store.delete(row.thought)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .overlay {
            SearchOutcomeView(model: model, text: search)
        }
    }

    private var archiveList: some View {
        List(archived) { thought in
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
            if archived.isEmpty {
                ContentUnavailableView(
                    "Archive is empty",
                    systemImage: "archivebox",
                    description: Text("Swipe left on a thought to archive it.")
                )
            }
        }
    }
}
