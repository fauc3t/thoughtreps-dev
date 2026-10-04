import Foundation

/// A whole-day interval expressed in the unit a person would pick it in.
/// Storage stays in days (`Thought.intervalDays`); a week is 7 days and a month is 30.
struct IntervalDuration: Equatable {
    enum Unit: CaseIterable {
        case day, week, month

        var days: Int {
            switch self {
            case .day: 1
            case .week: 7
            case .month: 30
            }
        }

        /// Largest count that stays within `Scheduler.maxIntervalDays`.
        var counts: ClosedRange<Int> {
            1...(Scheduler.maxIntervalDays / days)
        }

        func name(count: Int) -> String {
            let base = switch self {
            case .day: "day"
            case .week: "week"
            case .month: "month"
            }
            return count == 1 ? base : base + "s"
        }
    }

    let unit: Unit
    let count: Int

    init(unit: Unit, count: Int) {
        self.unit = unit
        self.count = min(max(count, unit.counts.lowerBound), unit.counts.upperBound)
    }

    /// Picks the most natural unit: multiples of 30 are months, multiples of 7 weeks, anything else days.
    init(days: Int) {
        let days = Scheduler.clamp(days)
        if days % Unit.month.days == 0 {
            self.init(unit: .month, count: days / Unit.month.days)
        } else if days % Unit.week.days == 0 {
            self.init(unit: .week, count: days / Unit.week.days)
        } else {
            self.init(unit: .day, count: days)
        }
    }

    var days: Int { count * unit.days }

    /// "Day", "Week", "Month" for a single unit; otherwise "5 days", "3 weeks".
    var label: String {
        count == 1 ? unit.name(count: 1).capitalized : "\(count) \(unit.name(count: count))"
    }

    /// For sentences: "Every \(phrase)".
    var phrase: String { label.lowercased() }

    /// The same duration in another unit, rounded to the nearest whole count within that unit's range.
    func with(unit newUnit: Unit) -> IntervalDuration {
        IntervalDuration(unit: newUnit, count: Int((Double(days) / Double(newUnit.days)).rounded()))
    }
}

/// Interval choices offered in the editor and thought view.
enum IntervalOption {
    static let choices = [1, 3, 7, 14, 30, 90]

    /// The presets plus `current`, when it is a custom value.
    static func choices(including current: Int?) -> [Int] {
        Array(Set(choices + [current].compactMap { $0 }.map(Scheduler.clamp))).sorted()
    }
}
