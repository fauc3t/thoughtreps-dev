import Foundation
import Testing
@testable import ThoughtReps

struct ReminderTimeTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func roundTripsMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for minutes in [0, 480, 755, 1439] {
            let date = ReminderTime.date(minutes: minutes, now: now, calendar: calendar)
            #expect(ReminderTime.minutes(from: date, calendar: calendar) == minutes)
        }
    }

    @Test func roundTripsOnSpringForwardDay() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ny.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        for minutes in [0, 60, 480, 1439] {
            let date = ReminderTime.date(minutes: minutes, now: now, calendar: ny)
            #expect(ReminderTime.minutes(from: date, calendar: ny) == minutes)
        }
    }
}
