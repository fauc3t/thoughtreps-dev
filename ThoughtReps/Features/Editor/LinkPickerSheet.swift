import SwiftUI
import SwiftData

enum LinkPicker {
    /// Archived thoughts can't be newly linked, and neither can the thought being edited or one it already links.
    static func isEligible(_ thought: Thought, excluding excluded: Set<UUID>) -> Bool {
        !thought.isArchived && !excluded.contains(thought.id)
    }

}

/// Chooses the thought a new link block points to: search over active thoughts, or the recent ones when
/// the query is empty or the search index is still catching up.
struct LinkPickerSheet: View {
    let excluded: Set<UUID>
    let onPick: (UUID) -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        LinkPickerContent(context: context, excluded: excluded, onPick: onPick)
    }
}

private struct LinkPickerContent: View {
    let excluded: Set<UUID>
    let onPick: (UUID) -> Void

    let context: ModelContext
    @Environment(\.dismiss) private var dismiss
    private struct SearchTaskID: Equatable {
        var text: String
        var isIndexing: Bool
    }

    @State private var model: SearchModel
    @State private var recents: [Thought] = []
    @State private var text = ""
    private var indexStatus = SearchIndexStatus.shared

    init(context: ModelContext, excluded: Set<UUID>, onPick: @escaping (UUID) -> Void) {
        self.context = context
        self.excluded = excluded
        self.onPick = onPick
        _model = State(initialValue: SearchModel(scope: .active, context: context) {
            LinkPicker.isEligible($0, excluding: excluded)
        })
    }

    private var isSearching: Bool { SearchModel.isSearchable(text) && !indexStatus.isIndexing }
    private var isCatchingUp: Bool { SearchModel.isSearchable(text) && indexStatus.isIndexing }
    private var rows: [SearchModel.Row] { model.liveRows }

    var body: some View {
        NavigationStack {
            List {
                if isCatchingUp {
                    Text("Search is catching up. Showing recent thoughts for now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                if isSearching {
                    ForEach(rows) { row in
                        Button { pick(row.thought.id) } label: {
                            LinkPickerRow(thought: row.thought, snippet: row.result.attributedSnippet)
                        }
                        .task { await model.loadMoreIfNeeded(after: row) }
                    }
                } else {
                    ForEach(recents) { thought in
                        Button { pick(thought.id) } label: {
                            LinkPickerRow(thought: thought, snippet: AttributedString(thought.preview))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay { emptyState }
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search thoughts")
            .navigationTitle("Link a thought")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .onAppear { recents = ThoughtCounts.recentForPicker(excluding: Array(excluded), in: context) }
            .task(id: SearchTaskID(text: text, isIndexing: indexStatus.isIndexing)) {
                guard !indexStatus.isIndexing else { return }
                await model.search(text)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            if model.failed {
                ContentUnavailableView(
                    "Search isn't available right now",
                    systemImage: "exclamationmark.magnifyingglass",
                    description: Text("Try again in a moment.")
                )
            } else if model.loadedQuery == SearchModel.trimmed(text), rows.isEmpty {
                ContentUnavailableView("No thoughts match", systemImage: "magnifyingglass")
            }
        } else if recents.isEmpty {
            ContentUnavailableView("No thoughts to link", systemImage: "link", description: Text("Write another thought first."))
        }
    }

    private func pick(_ id: UUID) {
        onPick(id)
        dismiss()
    }
}

private struct LinkPickerRow: View {
    let thought: Thought
    let snippet: AttributedString

    private var tags: String {
        thought.sortedTags.map { "#\($0.displayName)" }.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(thought.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !snippet.characters.isEmpty {
                Text(snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !tags.isEmpty {
                Text(tags)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Link to \(thought.title)")
        .accessibilityValue([String(snippet.characters), tags].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}
