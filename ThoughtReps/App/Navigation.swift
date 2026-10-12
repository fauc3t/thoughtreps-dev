import SwiftUI

/// Everything a navigation stack can push. One value type, so a stack's path can be read back and
/// carried between the compact and split layouts.
enum AppRoute: Hashable {
    case thought(Thought)
    case tag(Tag)
    case untagged
    case search
}

/// What survives a switch between the compact tabs and the split view (a fold or unfold).
enum LayoutCarry {
    /// Compact -> split: the last thought on the stack becomes the detail column's selection and the
    /// other pushed screens become the content column's stack.
    static func unfold(compactPath: [AppRoute]) -> (thought: Thought?, contentPath: [AppRoute]) {
        var thought: Thought?
        var rest: [AppRoute] = []
        for route in compactPath {
            if case .thought(let pushed) = route {
                if pushed.modelContext != nil, !pushed.isDeleted { thought = pushed }
            } else {
                rest.append(route)
            }
        }
        return (thought, rest)
    }

    /// Split -> compact: the selected thought is pushed on top of the content column's screens.
    static func fold(contentPath: [AppRoute], selected: Thought?) -> [AppRoute] {
        guard let selected else { return contentPath }
        return contentPath + [.thought(selected)]
    }
}

/// A one-shot note that the next detail screen for this thought is the same open, moved across a
/// layout switch, so it must not be recorded as another view. An offer nobody takes expires, so it
/// can't swallow a genuine open later.
@MainActor
@Observable
final class ViewHandoff {
    static let window: TimeInterval = 1

    private var offered: (id: UUID, at: Date)?

    func offer(_ id: UUID, now: Date) { offered = (id, now) }

    /// True once for an offered id, if taken within the window.
    func consume(_ id: UUID, now: Date) -> Bool {
        guard let offered, offered.id == id else { return false }
        self.offered = nil
        return now.timeIntervalSince(offered.at) <= Self.window
    }

    /// Whether opening a detail screen records a view; a handed-off open never does.
    static func recordsView(hasRecordedView: Bool, isArchived: Bool, handedOff: Bool) -> Bool {
        !hasRecordedView && !isArchived && !handedOff
    }
}

extension View {
    /// Registers the app's push destinations. Apply once at the root of each NavigationStack.
    func thoughtDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            switch route {
            case .thought(let thought): ThoughtDetailView(thought: thought)
            case .tag(let tag): TagTimelineView(tag: tag)
            case .untagged: ThoughtTimelineView(scope: .untagged)
            case .search: SearchView()
            }
        }
    }
}
