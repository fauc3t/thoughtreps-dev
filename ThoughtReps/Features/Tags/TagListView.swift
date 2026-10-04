import SwiftUI
import SwiftData

/// Every tag in use, with how many of its thoughts are due.
struct TagListView: View {
    @Query(sort: \Tag.name) private var tags: [Tag]
    @State private var filter = ""
    @State private var now = Date.now

    private var visible: [Tag] {
        tags.filter { tag in
            !tag.activeThoughts.isEmpty
                && (filter.isEmpty || tag.name.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        List(visible) { tag in
            NavigationLink(value: tag) {
                TagRow(tag: tag, now: now)
            }
        }
        .overlay {
            if visible.isEmpty {
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
        .accessibilityElement(children: .combine)
    }
}

/// A single tag's timeline.
struct TagTimelineView: View {
    let tag: Tag

    var body: some View {
        ThoughtTimelineView(tag: tag)
    }
}

#Preview {
    NavigationStack {
        TagListView()
            .thoughtDestinations()
    }
    .modelContainer(PreviewData.container)
}
