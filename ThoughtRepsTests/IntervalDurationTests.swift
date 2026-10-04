import Testing
@testable import ThoughtReps

@Suite("IntervalDuration")
struct IntervalDurationTests {
    @Test("Days decompose into the most natural unit", arguments: [
        (5, IntervalDuration.Unit.day, 5),
        (1, .day, 1),
        (7, .week, 1),
        (14, .week, 2),
        (21, .week, 3),
        (30, .month, 1),
        (60, .month, 2),
        (90, .month, 3),
        (45, .day, 45),
        (210, .month, 7),
    ])
    func decomposition(days: Int, unit: IntervalDuration.Unit, count: Int) {
        let duration = IntervalDuration(days: days)
        #expect(duration.unit == unit)
        #expect(duration.count == count)
    }

    @Test("Labels", arguments: [
        (1, "Day"), (3, "3 days"), (5, "5 days"), (7, "Week"), (14, "2 weeks"),
        (21, "3 weeks"), (30, "Month"), (60, "2 months"), (90, "3 months"), (45, "45 days"),
    ])
    func labels(days: Int, label: String) {
        #expect(IntervalDuration(days: days).label == label)
    }

    @Test func phraseIsLowercase() {
        #expect(IntervalDuration(days: 7).phrase == "week")
        #expect(IntervalDuration(days: 14).phrase == "2 weeks")
    }

    @Test func daysClampToSchedulerBounds() {
        #expect(IntervalDuration(days: 0).days == 1)
        #expect(IntervalDuration(days: -4).days == 1)
        #expect(IntervalDuration(days: 1000).days == Scheduler.maxIntervalDays)
    }

    @Test func unitRangesStayWithinMax() {
        #expect(IntervalDuration.Unit.day.counts == 1...365)
        #expect(IntervalDuration.Unit.week.counts == 1...52)
        #expect(IntervalDuration.Unit.month.counts == 1...12)
        for unit in IntervalDuration.Unit.allCases {
            #expect(IntervalDuration(unit: unit, count: 1000).days <= Scheduler.maxIntervalDays)
            #expect(IntervalDuration(unit: unit, count: 0).count == 1)
        }
    }

    @Test func changingUnitPreservesDurationRoundedToNearest() {
        #expect(IntervalDuration(unit: .day, count: 200).with(unit: .week) == IntervalDuration(unit: .week, count: 29))
        #expect(IntervalDuration(unit: .week, count: 40).with(unit: .month) == IntervalDuration(unit: .month, count: 9))
        #expect(IntervalDuration(unit: .week, count: 2).with(unit: .day) == IntervalDuration(unit: .day, count: 14))
    }

    @Test func changingUnitClampsToRangeAndMinimum() {
        #expect(IntervalDuration(unit: .day, count: 365).with(unit: .month) == IntervalDuration(unit: .month, count: 12))
        #expect(IntervalDuration(unit: .day, count: 2).with(unit: .month) == IntervalDuration(unit: .month, count: 1))
    }

    @Test func roundTripsDays() {
        for days in 1...Scheduler.maxIntervalDays {
            #expect(IntervalDuration(days: days).days == days)
        }
    }

    @Test func choicesWithoutCurrentAreThePresets() {
        #expect(IntervalOption.choices(including: nil) == IntervalOption.choices)
    }

    @Test func choicesDoNotDuplicatePresets() {
        #expect(IntervalOption.choices(including: 7) == IntervalOption.choices)
    }

    @Test func choicesInsertCustomValueInOrder() {
        #expect(IntervalOption.choices(including: 10) == [1, 3, 7, 10, 14, 30, 90])
    }

    @Test func choicesClampOutOfRangeValue() {
        #expect(IntervalOption.choices(including: 400) == IntervalOption.choices + [365])
        #expect(IntervalOption.choices(including: 0) == IntervalOption.choices)
    }
}
