import SwiftUI

/// One row on a timeline: title, a two-line preview, tags and when it's due.
struct ThoughtCard: View {
    let thought: Thought
    let now: Date

    private static let thumbnailSize: CGFloat = 56

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            content
            if let image = thought.firstImage {
                DataImage(id: image.id) { image.thumbnailData }
                    .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(thought.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if thought.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Pinned")
                }
            }
            if !thought.preview.isEmpty {
                Text(thought.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                TagChips(tags: thought.sortedTags, linked: false)
                Spacer(minLength: 0)
                if !thought.isPinned {
                    DueLabel(date: thought.nextDueAt, now: now)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// "due today", "due 2d ago" (highlighted), or "in 5 days".
struct DueLabel: View {
    let date: Date
    let now: Date

    var body: some View {
        let days = RelativeDay.daysBetween(date, and: now)
        Text(text(days: days))
            .font(.caption.weight(.medium))
            .foregroundStyle(days > 0 ? Color.orange : Color.secondary)
    }

    private func text(days: Int) -> String {
        switch days {
        case ..<0: "in \(-days) \(-days == 1 ? "day" : "days")"
        case 0: date <= now ? "due today" : "later today"
        default: "due \(days)d ago"
        }
    }
}

/// Calendar-day phrasing shared by the timeline and thought view.
enum RelativeDay {
    /// Whole calendar days from `date` to `now` (positive = `date` is in the past).
    static func daysBetween(_ date: Date, and now: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// "today", "tomorrow", "in 4 days", "on Oct 20".
    static func phrase(for date: Date, now: Date) -> String {
        let ahead = -daysBetween(date, and: now)
        switch ahead {
        case ...0: return "today"
        case 1: return "tomorrow"
        case 2...6: return "in \(ahead) days"
        default: return "on \(date.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }
}
