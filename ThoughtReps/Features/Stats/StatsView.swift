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
        .inkList()
        .contentMargins(.bottom, 88, for: .scrollContent)
        .navigationTitle("Stats")
        .overlay {
            if model.snapshot == nil { ProgressView() }
        }
        .task { await model.refresh(container: context.container, now: .now, calendar: calendar) }
    }

    private func basics(_ stats: ThoughtStats.Snapshot) -> some View {
        let seenDetail = "\(stats.seenAtLeastOnce) \(stats.seenAtLeastOnce == 1 ? "thought" : "thoughts") seen at least once"
        return Section {
            VStack(alignment: .leading, spacing: 14) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkCard()
            .inkRow()
        } header: {
            Text("Basics").inkSectionHeader()
        }
    }

    private func mostRevisitedSection(_ thought: Thought) -> some View {
        Section {
            NavigationLink(value: thought) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(thought.title)
                        .font(.archivo(17))
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                    if !thought.preview.isEmpty {
                        Text(thought.preview)
                            .thoughtTextFont()
                            .foregroundStyle(Color.muted)
                            .lineLimit(2)
                    }
                    Text("Seen \(thought.viewCount) times")
                        .font(.mono(11))
                        .foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .inkCard()
            }
            .inkRow()
            .accessibilityHint("Opens this thought")
        } header: {
            Text("Most revisited").inkSectionHeader()
        }
    }

    private func rhythm(_ stats: ThoughtStats.Snapshot) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                WritingRhythmGrid(weeks: stats.weeks)
                Text("\(stats.lastYear) \(stats.lastYear == 1 ? "thought" : "thoughts") in the last year")
                    .font(.mono(11))
                    .foregroundStyle(Color.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkCard()
            .inkRow()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.rhythmLabel(stats))
        } header: {
            Text("Writing rhythm").inkSectionHeader()
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
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mono(12, relativeTo: .footnote))
                    .foregroundStyle(Color.muted)
                if let detail {
                    Text(detail)
                        .font(.mono(11))
                        .foregroundStyle(Color.muted)
                }
            }
            Spacer(minLength: 8)
            Text(ThoughtStats.compactCount(value))
                .font(.archivo(28, weight: .bold, relativeTo: .title))
                .foregroundStyle(Color.ink)
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
                        .fill(Color.soft)
                        .overlay { shape.strokeBorder(Color.hl, lineWidth: 1) }
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    shape
                        .fill(Color.ink.opacity(Self.steps[level - 1]))
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
