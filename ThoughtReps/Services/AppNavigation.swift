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

/// A request to resolve a conflict copy, held by id and presented from the root like the editor.
struct ResolveConflictRequest: Identifiable, Equatable {
    let id: UUID
}

/// A request for a new thought. One from the Action button or Siri skips the current tag's prefill.
struct NewThoughtRequest: Equatable {
    let skipsTagPrefill: Bool

    func prefillTag(current: String?) -> String? {
        skipsTagPrefill ? nil : current
    }
}

/// App-wide navigation state that outside callers (the notification delegate, keyboard commands) can drive.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    var selectedTab: AppTab = .timeline
    var showSettings = false
    var editRequest: EditThoughtRequest?
    var resolveRequest: ResolveConflictRequest?
    /// Increments on each reminder tap.
    private(set) var reminderOpenCount = 0
    /// Held until the root consumes it, so a request made before the root mounts (cold launch) isn't missed.
    private(set) var pendingNewThought: NewThoughtRequest?
    private(set) var searchRequestCount = 0

    func openTimelineFromReminder() {
        selectedTab = .timeline
        showSettings = false
        reminderOpenCount += 1
    }

    func requestNewThought(skipsTagPrefill: Bool = false) {
        guard !ModalPresence.isPresenting else { return }
        pendingNewThought = NewThoughtRequest(skipsTagPrefill: skipsTagPrefill)
    }

    /// Takes the pending request so it is handled exactly once.
    func consumeNewThought() -> NewThoughtRequest? {
        let request = pendingNewThought
        pendingNewThought = nil
        return request
    }

    func requestEdit(thoughtID: UUID) {
        guard editRequest == nil else { return }
        editRequest = EditThoughtRequest(id: thoughtID)
    }

    func requestResolve(copyID: UUID) {
        guard resolveRequest == nil else { return }
        resolveRequest = ResolveConflictRequest(id: copyID)
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
