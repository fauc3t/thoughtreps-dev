import SwiftUI
import SwiftData

/// Full-text search over thoughts, pushed from the main timeline.
struct SearchView: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        SearchContent(context: context)
    }
}

private struct SearchContent: View {
    @State private var model: SearchModel
    @State private var text = ""
    @State private var now = Date.now
    @State private var hasFocused = false
    @FocusState private var searchFocused: Bool
    private var indexStatus = SearchIndexStatus.shared

    private struct TaskID: Equatable {
        var text: String
        var scope: SearchScope
    }

    init(context: ModelContext) {
        _model = State(initialValue: SearchModel(scope: .active, context: context))
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $model.scope) {
                    Text("Active").tag(SearchScope.active)
                    Text("Archived").tag(SearchScope.archived)
                    Text("All").tag(SearchScope.all)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            }
            if indexStatus.isIndexing {
                Text("Indexing… results may be incomplete.")
                    .font(.mono(12, relativeTo: .footnote))
                    .foregroundStyle(Color.muted)
                    .inkRow()
            }
            ForEach(model.liveRows) { row in
                SearchResultLink(row: row, model: model, now: now)
            }
        }
        .inkList()
        .readableContentMargins()
        .overlay { emptyState }
        .searchable(text: $text, prompt: "Search thoughts")
        .searchFocused($searchFocused)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            now = .now
            model.pruneRows()
            if !hasFocused {
                hasFocused = true
                searchFocused = true
            }
        }
        .task(id: TaskID(text: text, scope: model.scope)) {
            await model.search(text)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if SearchModel.isSearchable(text) {
            SearchOutcomeView(model: model, text: text)
        } else {
            ContentUnavailableView(
                "Search your thoughts",
                systemImage: "magnifyingglass",
                description: Text("Type at least \(SearchModel.minimumLength) characters.")
            )
        }
    }
}

/// Route value for the search screen.
struct SearchRoute: Hashable {}
