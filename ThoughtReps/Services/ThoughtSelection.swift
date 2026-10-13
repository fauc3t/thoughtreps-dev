import Foundation
import Observation
import SwiftData

/// Which thought the split view shows in its detail column. Only injected into the environment in the
/// split layout; where it is absent (the compact tabs) thoughts push onto the navigation stack instead.
///
/// Holds identifiers, never the model, so a thought deleted elsewhere can't be rendered dead: the
/// detail column resolves the selection with a query and shows the placeholder when nothing matches.
@MainActor
@Observable
final class ThoughtSelection {
    struct Pick: Equatable {
        /// For the detail column's primary-key lookup.
        let modelID: PersistentIdentifier
        /// For the timeline predicate, which keeps this thought's card listed.
        let id: UUID
    }

    private(set) var current: Pick?
    /// A tag tapped in the detail column. The content column shows its timeline, then clears this.
    var pendingTag: Tag?
    /// Linked thoughts pushed on the detail column, above the selection. Following a link leaves the selection alone;
    /// choosing or clearing a selection starts the stack over.
    var detailPath: [AppRoute] = []
    /// Cleared on every select or clear: a new open is genuine, not a carried one.
    weak var viewHandoff: ViewHandoff?

    func select(_ thought: Thought) {
        detailPath = []
        viewHandoff?.clear()
        current = Pick(modelID: thought.persistentModelID, id: thought.id)
    }

    func clear() {
        detailPath = []
        viewHandoff?.clear()
        current = nil
    }

    /// Call before deleting a thought from outside the detail column, so no view renders it afterwards.
    func clear(ifSelected thought: Thought) {
        if isSelected(thought) {
            clear()
        } else if let index = detailPath.firstIndex(where: { route in
            if case .linkedThought(let visited) = route { visited.persistentModelID == thought.persistentModelID } else { false }
        }) {
            detailPath.removeSubrange(index...)
        }
    }

    func isSelected(_ thought: Thought) -> Bool {
        current?.modelID == thought.persistentModelID
    }
}
