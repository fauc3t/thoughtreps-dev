import SwiftUI
import SwiftData

/// Every tag in use, with how many of its thoughts are due, plus an Untagged row for
/// thoughts that have no tag.
struct TagListView: View {
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(filter: #Predicate<Thought> { $0.isArchived == false })
    private var activeThoughts: [Thought]
    @State private var filter = ""
    @State private var now = Date.now

    private var visible: [Tag] {
        tags.filter { tag in
            !tag.activeThoughts.isEmpty
                && (filter.isEmpty || tag.name.localizedCaseInsensitiveContains(filter))
        }
    }

    private var untagged: [Thought] {
        filter.isEmpty ? activeThoughts.filter(\.isUntagged) : []
    }

    var body: some View {
        List {
            ForEach(visible) { tag in
                NavigationLink(value: tag) {
                    TagRow(tag: tag, now: now)
                }
            }
            if !untagged.isEmpty {
                Section {
                    NavigationLink(value: UntaggedRoute()) {
                        UntaggedRow(thoughts: untagged, now: now)
                    }
                }
            }
        }
        .overlay {
            if visible.isEmpty && untagged.isEmpty {
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
        .onAppear { now = .now }
    }
}

struct TagRow: View {
    let tag: Tag
    let now: Date

    var body: some View {
        let due = tag.dueCount(now: now)
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
            Text("\(tag.activeThoughts.count)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            RowAccessibility.label(title: "#\(tag.displayName)", due: due, count: tag.activeThoughts.count)
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
    let thoughts: [Thought]
    let now: Date

    var body: some View {
        let due = thoughts.filter { Scheduler.isDue(nextDueAt: $0.nextDueAt, now: now) }.count
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
            Text("\(thoughts.count)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RowAccessibility.label(title: "Untagged", due: due, count: thoughts.count))
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
