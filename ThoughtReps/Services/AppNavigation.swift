import Foundation
import Observation

enum AppTab: Int, CaseIterable, Hashable {
    case timeline, tags, archive, stats

    var title: String {
        switch self {
        case .timeline: "Timeline"
        case .tags: "Tags"
        case .archive: "Archive"
        case .stats: "Stats"
        }
    }

    var systemImage: String {
        switch self {
        case .timeline: "text.alignleft"
        case .tags: "number"
        case .archive: "archivebox"
        case .stats: "chart.bar"
        }
    }

    var shortcutNumber: Int { rawValue + 1 }

    /// The section a ⌘1 to ⌘4 shortcut opens.
    init?(shortcutNumber: Int) {
        guard let tab = Self.allCases.first(where: { $0.shortcutNumber == shortcutNumber }) else { return nil }
        self = tab
    }
}

/// A request to edit a thought, held by id: the editor is presented from the root so it outlives a layout change.
struct EditThoughtRequest: Identifiable, Equatable {
    let id: UUID
}

/// App-wide navigation state that outside callers (the notification delegate, keyboard commands) can drive.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    var selectedTab: AppTab = .timeline
    var showSettings = false
    var editRequest: EditThoughtRequest?
    /// Increments on each reminder tap.
    private(set) var reminderOpenCount = 0
    /// Each increments per keyboard command; whichever layout is on screen reacts to the change.
    private(set) var newThoughtRequestCount = 0
    private(set) var searchRequestCount = 0

    func openTimelineFromReminder() {
        selectedTab = .timeline
        showSettings = false
        reminderOpenCount += 1
    }

    func requestNewThought() {
        guard !ModalPresence.isPresenting else { return }
        newThoughtRequestCount += 1
    }

    func requestEdit(thoughtID: UUID) {
        guard editRequest == nil else { return }
        editRequest = EditThoughtRequest(id: thoughtID)
    }

    func requestSearch() {
        guard !ModalPresence.isPresenting else { return }
        selectedTab = .timeline
        searchRequestCount += 1
    }

    func requestSettings() {
        guard !ModalPresence.isPresenting else { return }
        showSettings = true
    }

    func requestTab(_ tab: AppTab) {
        guard !ModalPresence.isPresenting else { return }
        selectedTab = tab
    }
}
