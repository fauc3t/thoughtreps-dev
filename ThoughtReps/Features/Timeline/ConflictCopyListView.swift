import SwiftUI
import SwiftData

/// Every conflict copy, a page at a time, for when the timeline's "Needs a look" section has more than it lists.
struct ConflictCopyListView: View {
    private static let pageSize = 50

    @Environment(\.modelContext) private var context
    @State private var limit = Self.pageSize
    @State private var copies: (thoughts: [Thought], total: Int) = ([], 0)
    @State private var originals: [UUID: Thought] = [:]
    @State private var saveToken = 0

    var body: some View {
        let rows = copies.thoughts.filter { $0.modelContext != nil && !$0.isDeleted }
        List {
            ForEach(rows) { copy in
                ConflictCopyRow(copy: copy, original: original(of: copy), now: .now)
                    .inkRow()
            }
            if copies.total > rows.count {
                Button("Show more") { limit += Self.pageSize }
                    .font(.mono(12, relativeTo: .footnote))
                    .foregroundStyle(Color.muted)
                    .inkRow()
            }
        }
        .inkList()
        .readableContentMargins()
        .navigationTitle("Needs a look")
        .overlay {
            if copies.total == 0 {
                ContentUnavailableView {
                    Label("Nothing to sort out", systemImage: "checkmark.circle")
                        .font(.archivo(22, weight: .bold, relativeTo: .title2))
                }
            }
        }
        .onChange(of: saveToken, initial: true) { refresh() }
        .onChange(of: limit) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in saveToken += 1 }
    }

    private func refresh() {
        let page = ThoughtCounts.conflictCopies(limit: limit, in: context)
        copies = page
        originals = ThoughtCounts.targets(of: page.thoughts.compactMap(\.conflictOfID), in: context)
    }

    private func original(of copy: Thought) -> Thought? {
        guard let id = copy.conflictOfID, let found = originals[id], found.modelContext != nil, !found.isDeleted else { return nil }
        return found
    }
}
