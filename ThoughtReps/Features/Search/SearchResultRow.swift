import SwiftUI

/// Where a search hit stands, as a short label. Pinned thoughts get the pin icon instead.
enum SearchStatus: Equatable {
    case archived
    case due
    case laterToday
    case backIn(days: Int)

    static func of(isArchived: Bool, isPinned: Bool, nextDueAt: Date, now: Date) -> SearchStatus? {
        if isArchived { return .archived }
        if isPinned { return nil }
        if nextDueAt <= now { return .due }
        let days = -RelativeDay.daysBetween(nextDueAt, and: now)
        return days <= 0 ? .laterToday : .backIn(days: days)
    }

    var text: String {
        switch self {
        case .archived: "Archived"
        case .due: "Due"
        case .laterToday: "Back later today"
        case .backIn(let days): "Back in \(days) \(days == 1 ? "day" : "days")"
        }
    }
}

/// One search hit: title, the highlighted snippet, tags and where the thought stands.
struct SearchResultRow: View {
    let row: SearchModel.Row
    let now: Date

    var body: some View {
        let thought = row.thought
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(thought.title)
                    .font(.archivo(17))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if thought.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(Color.muted)
                        .accessibilityLabel("Pinned")
                }
                if let status = SearchStatus.of(
                    isArchived: thought.isArchived, isPinned: thought.isPinned, nextDueAt: thought.nextDueAt, now: now
                ) {
                    InkBadge(text: status.text, style: status == .due ? .overdue : .plain)
                }
            }
            Text(row.result.attributedSnippet)
                .font(.subheadline)
                .foregroundStyle(Color.muted)
                .lineLimit(2)
            if !thought.sortedTags.isEmpty {
                TagChips(tags: thought.sortedTags, linked: false)
            }
        }
        .inkCard()
    }
}

/// A result row that opens its thought and pages in more results when it is the last one.
struct SearchResultLink: View {
    let row: SearchModel.Row
    let model: SearchModel
    let now: Date

    var body: some View {
        NavigationLink(value: row.thought) {
            SearchResultRow(row: row, now: now)
        }
        .inkRow()
        .task { await model.loadMoreIfNeeded(after: row) }
    }
}

/// The no-results and error states for the current query; nothing while results are showing or loading.
struct SearchOutcomeView: View {
    let model: SearchModel
    let text: String

    var body: some View {
        if model.loadedQuery == SearchModel.trimmed(text) {
            if model.failed {
                ContentUnavailableView(
                    "Search isn't available right now",
                    systemImage: "exclamationmark.magnifyingglass",
                    description: Text("Try again in a moment.")
                )
            } else if model.rows.isEmpty {
                ContentUnavailableView.search(text: text)
            }
        }
    }
}
