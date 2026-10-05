import SwiftUI
import SwiftData

/// Every tag in use, with how many of its thoughts are due, plus an Untagged row for
/// thoughts that have no tag.
struct TagListView: View {
    struct Counts: Equatable {
        var active = 0
        var due = 0
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \Tag.name) private var tags: [Tag]
    @State private var filter = ""
    @State private var now = Date.now
    @State private var tagCounts: [String: Counts] = [:]
    @State private var untaggedCounts = Counts()

    private var visible: [Tag] {
        tags.filter { tag in
            (tagCounts[tag.name]?.active ?? 0) > 0
                && (filter.isEmpty || tag.name.localizedCaseInsensitiveContains(filter))
        }
    }

    private var showsUntagged: Bool {
        filter.isEmpty && untaggedCounts.active > 0
    }

    var body: some View {
        List {
            ForEach(visible) { tag in
                NavigationLink(value: tag) {
                    TagRow(tag: tag, counts: tagCounts[tag.name] ?? Counts())
                }
            }
            if showsUntagged {
                Section {
                    NavigationLink(value: UntaggedRoute()) {
                        UntaggedRow(counts: untaggedCounts)
                    }
                }
            }
        }
        .overlay {
            if visible.isEmpty && !showsUntagged {
                if filter.isEmpty {
                    ContentUnavailableView(
                        "No tags yet",
                        systemImage: "number",
                        description: Text("Add #tags to a thought and they show up here.")
                    )
                } else {
                    ContentUnavailableView.search(text: filter)
                }
            }
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        .searchable(text: $filter, prompt: "Filter tags")
        .navigationTitle("Tags")
        .onAppear {
            now = .now
            refreshCounts()
        }
        .onChange(of: tags.map(\.name)) { refreshCounts() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave, object: context)) { _ in refreshCounts() }
    }

    /// Counts are queries, not `@Query` results, so they are recomputed on appear and after every
    /// save (all writes go through `ThoughtStore.persist()`), not on every render.
    private func refreshCounts() {
        tagCounts = Dictionary(
            tags.map { tag in
                (
                    tag.name,
                    Counts(
                        active: ThoughtCounts.count(ThoughtCounts.active(tag: tag.name), in: context),
                        due: ThoughtCounts.count(ThoughtCounts.due(tag: tag.name, now: now), in: context)
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
        untaggedCounts = Counts(
            active: ThoughtCounts.count(ThoughtCounts.untagged, in: context),
            due: ThoughtCounts.count(ThoughtCounts.dueUntagged(now: now), in: context)
        )
    }
}

struct TagRow: View {
    let tag: Tag
    let counts: TagListView.Counts

    var body: some View {
        let due = counts.due
        HStack(spacing: 12) {
            Circle()
                .fill(TagColor.color(for: tag))
                .frame(width: 10, height: 10)
            Text("#\(tag.displayName)")
                .font(.body.weight(.medium))
            Spacer()
            if due > 0 {
                Text("\(due) due")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            }
            Text("\(counts.active)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            RowAccessibility.label(title: "#\(tag.displayName)", due: due, count: counts.active)
        )
    }
}

private enum RowAccessibility {
    static func label(title: String, due: Int, count: Int) -> String {
        let noun = count == 1 ? "thought" : "thoughts"
        let dueText = due > 0 ? ", \(due) due" : ""
        return "\(title)\(dueText), \(count) \(noun)"
    }
}

struct UntaggedRow: View {
    let counts: TagListView.Counts

    var body: some View {
        let due = counts.due
        HStack(spacing: 12) {
            Circle()
                .fill(.secondary)
                .frame(width: 10, height: 10)
            Text("Untagged")
                .font(.body.weight(.medium))
            Spacer()
            if due > 0 {
                Text("\(due) due")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
            }
            Text("\(counts.active)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowAccessibility.label(title: "Untagged", due: due, count: counts.active))
    }
}

/// A single tag's timeline.
struct TagTimelineView: View {
    let tag: Tag

    var body: some View {
        ThoughtTimelineView(scope: .tag(tag))
    }
}

/// Route value for the untagged timeline.
struct UntaggedRoute: Hashable {}

#Preview {
    NavigationStack {
        TagListView()
            .thoughtDestinations()
    }
    .modelContainer(PreviewData.container)
}
