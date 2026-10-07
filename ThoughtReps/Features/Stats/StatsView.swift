import SwiftUI
import SwiftData

/// A quiet read-out of how the app is being used: totals, the most revisited thought, and
/// how much was written each week of the last year.
struct StatsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.calendar) private var calendar
    @State private var model = StatsModel()

    @Query(ThoughtStats.mostRevisited) private var mostRevisited: [Thought]

    var body: some View {
        List {
            if let snapshot = model.snapshot {
                basics(snapshot)
                if let thought = mostRevisited.first {
                    mostRevisitedSection(thought)
                }
                rhythm(snapshot)
            }
        }
        .contentMargins(.bottom, 88, for: .scrollContent)
        .navigationTitle("Stats")
        .overlay {
            if model.snapshot == nil { ProgressView() }
        }
        .task { await model.refresh(container: context.container, now: .now, calendar: calendar) }
    }

    private func basics(_ stats: ThoughtStats.Snapshot) -> some View {
        let seenDetail = "\(stats.seenAtLeastOnce) \(stats.seenAtLeastOnce == 1 ? "thought" : "thoughts") seen at least once"
        return Section("Basics") {
            StatRow(
                title: "Thoughts written",
                value: stats.total,
                detail: "\(stats.thisMonth) this month",
                label: "Thoughts written, \(stats.total), \(stats.thisMonth) this month"
            )
            StatRow(
                title: "Revisits",
                value: stats.totalViews,
                detail: seenDetail,
                label: "Revisits, \(stats.totalViews), \(seenDetail)"
            )
            StatRow(
                title: "Active",
                value: stats.active,
                detail: nil,
                label: "Active thoughts, \(stats.active)"
            )
            StatRow(
                title: "Archived",
                value: stats.archived,
                detail: nil,
                label: "Archived thoughts, \(stats.archived)"
            )
        }
    }

    private func mostRevisitedSection(_ thought: Thought) -> some View {
        Section("Most revisited") {
            NavigationLink(value: thought) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(thought.title)
                        .font(.headline)
                        .lineLimit(2)
                    if !thought.preview.isEmpty {
                        Text(thought.preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text("Seen \(thought.viewCount) times")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .accessibilityHint("Opens this thought")
        }
    }

    private func rhythm(_ stats: ThoughtStats.Snapshot) -> some View {
        Section("Writing rhythm") {
            VStack(alignment: .leading, spacing: 12) {
                WritingRhythmGrid(weeks: stats.weeks)
                Text("\(stats.lastYear) \(stats.lastYear == 1 ? "thought" : "thoughts") in the last year")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.rhythmLabel(stats))
        }
    }

    static func rhythmLabel(_ stats: ThoughtStats.Snapshot) -> String {
        let weeks = ThoughtStats.weekCount
        guard stats.lastYear > 0 else { return "Writing rhythm, no thoughts in the last \(weeks) weeks" }
        let noun = stats.lastYear == 1 ? "thought" : "thoughts"
        return "Writing rhythm, \(stats.lastYear) \(noun) in the last \(weeks) weeks, busiest week \(stats.busiestWeek)"
    }
}

private struct StatRow: View {
    let title: String
    let value: Int
    let detail: String?
    let label: String

    var body: some View {
        LabeledContent {
            Text(value, format: .number)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// One square per week, oldest first, shaded by how many thoughts were created that week.
private struct WritingRhythmGrid: View {
    let weeks: [Int]

    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 13)
    private static let steps: [Double] = [0.4, 0.6, 0.8, 1]

    var body: some View {
        let busiest = weeks.max() ?? 0
        LazyVGrid(columns: Self.columns, spacing: 4) {
            ForEach(weeks.indices, id: \.self) { index in
                let level = ThoughtStats.level(count: weeks[index], busiest: busiest)
                let shape = RoundedRectangle(cornerRadius: 3)
                if level == 0 {
                    shape
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    shape
                        .fill(Color.accentColor.opacity(Self.steps[level - 1]))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        StatsView()
            .thoughtDestinations()
    }
    .modelContainer(PreviewData.container)
}
