import SwiftUI

/// One row on a timeline: title, a two-line preview, tags and when it's due. Pinned thoughts
/// get a compact card with just the pin and the title.
struct ThoughtCard: View {
    let thought: Thought
    let now: Date

    private static let thumbnailSize: CGFloat = 56

    var body: some View {
        if thought.isPinned {
            pinned
        } else {
            HStack(alignment: .top, spacing: 12) {
                content
                if let image = thought.firstImage {
                    DataImage(id: image.id) { image.thumbnailData }
                        .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                }
            }
            .inkCard()
        }
    }

    private var pinned: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(Color.muted)
                .accessibilityLabel("Pinned")
            Text(thought.title)
                .font(.archivo(16))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .inkCard(filled: true)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(thought.title)
                    .font(.archivo(17))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                Spacer(minLength: 0)
                DueLabel(date: thought.nextDueAt, now: now)
            }
            if !thought.preview.isEmpty {
                Text(thought.preview)
                    .font(.subheadline)
                    .foregroundStyle(Color.muted)
                    .lineLimit(2)
            }
            if !thought.sortedTags.isEmpty {
                TagChips(tags: thought.sortedTags, linked: false)
            }
        }
    }
}

/// "due today" (hl badge), "due 2d ago" (ink badge), or "in 5 days".
struct DueLabel: View {
    let date: Date
    let now: Date

    var body: some View {
        let days = RelativeDay.daysBetween(date, and: now)
        InkBadge(text: text(days: days), style: days > 0 ? .overdue : days == 0 ? .today : .plain)
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
