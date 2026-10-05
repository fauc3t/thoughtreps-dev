import SwiftUI

extension View {
    /// Registers the app's push destinations. Apply once at the root of each NavigationStack.
    func thoughtDestinations() -> some View {
        self
            .navigationDestination(for: Thought.self) { thought in
                ThoughtDetailView(thought: thought)
            }
            .navigationDestination(for: Tag.self) { tag in
                TagTimelineView(tag: tag)
            }
            .navigationDestination(for: UntaggedRoute.self) { _ in
                ThoughtTimelineView(scope: .untagged)
            }
    }
}
