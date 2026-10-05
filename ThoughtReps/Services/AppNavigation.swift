import Foundation
import Observation

enum AppTab: Hashable {
    case timeline, tags, archive
}

/// App-wide navigation state that outside callers (the notification delegate) can drive.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    var selectedTab: AppTab = .timeline
    /// Increments on each reminder tap so open sheets can dismiss themselves.
    private(set) var reminderOpenCount = 0

    func openTimelineFromReminder() {
        selectedTab = .timeline
        reminderOpenCount += 1
    }
}
