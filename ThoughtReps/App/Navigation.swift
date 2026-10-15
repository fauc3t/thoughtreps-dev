import SwiftUI

/// Everything a navigation stack can push. One value type, so a stack's path can be read back and
/// carried between the compact and split layouts.
enum AppRoute: Hashable {
    case thought(Thought)
    /// A thought reached by following a link card: counts as a view but never requeues.
    case linkedThought(Thought)
    case tag(Tag)
    case untagged
    case search
}

/// What survives a switch between the compact tabs and the split view (a fold or unfold).
enum LayoutCarry {
    /// Compact -> split: the last thought on the stack becomes the detail column's selection and the
    /// other pushed screens become the content column's stack. Linked-thought pushes above that thought
    /// stay pushes, on the detail column's stack (`detailPath`): selecting a visited thought would be a
    /// different kind of open. Ones below it belonged to an earlier thought and are dropped.
    static func unfold(compactPath: [AppRoute]) -> (thought: Thought?, contentPath: [AppRoute], detailPath: [AppRoute]) {
        var thought: Thought?
        var rest: [AppRoute] = []
        var detail: [AppRoute] = []
        for route in compactPath {
            switch route {
            case .thought(let pushed):
                if isLive(pushed) {
                    thought = pushed
                    detail = []
                }
            case .linkedThought(let visited):
                if thought != nil, isLive(visited) { detail.append(route) }
            default:
                rest.append(route)
            }
        }
        return (thought, rest, detail)
    }

    /// Split -> compact: the selected thought is pushed on top of the content column's screens, then
    /// the detail column's pushed linked thoughts.
    static func fold(contentPath: [AppRoute], selected: Thought?, detailPath: [AppRoute] = []) -> [AppRoute] {
        guard let selected else { return contentPath }
        let visits = detailPath.filter { route in
            if case .linkedThought(let visited) = route { isLive(visited) } else { false }
        }
        return contentPath + [.thought(selected)] + visits
    }

    /// Every thought entry of a carried stack: the selection and each live visit above it.
    static func carriedIDs(selected: Thought, detailPath: [AppRoute]) -> [UUID] {
        [selected.id] + detailPath.compactMap { route in
            if case .linkedThought(let visited) = route, isLive(visited) { visited.id } else { nil }
        }
    }

    private static func isLive(_ thought: Thought) -> Bool {
        thought.modelContext != nil && !thought.isDeleted
    }
}

/// The thoughts a fold or unfold carried across, as a count per id (a stack can hold the same thought
/// twice). Every remounted detail for a carried thought, including covered ones that appear later when
/// the stack pops, consumes one entry instead of recording another view. Nothing expires: a genuine new
/// open (`ThoughtSelection.select`/`clear`) or the next carry clears it.
@MainActor
@Observable
final class ViewHandoff {
    private var carried: [UUID: Int] = [:]

    /// Replaces any earlier carry with these thoughts, one per stack entry.
    func carry(_ ids: [UUID]) {
        carried = ids.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    func clear() { carried = [:] }

    /// True while a carried entry for this id is left, and uses it up.
    func consume(_ id: UUID) -> Bool {
        guard let count = carried[id], count > 0 else { return false }
        carried[id] = count == 1 ? nil : count - 1
        return true
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
            case .thought(let thought): ThoughtDetailLoader(modelID: thought.persistentModelID)
            case .linkedThought(let thought): ThoughtDetailLoader(modelID: thought.persistentModelID, openKind: .visit)
            case .tag(let tag): TagTimelineView(tag: tag)
            case .untagged: ThoughtTimelineView(scope: .untagged)
            case .search: SearchView()
            }
        }
    }
}
