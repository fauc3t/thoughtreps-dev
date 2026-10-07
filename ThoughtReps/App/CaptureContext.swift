import Foundation
import Observation

/// What the floating "+" should capture into. A tag's timeline registers while it's on screen.
/// Registrations are keyed by view instance, so appear/disappear events from a stray instance
/// can't clear the real page's tag whatever order they arrive in.
@Observable
final class CaptureContext {
    private var registrations: [(token: UUID, tag: Tag)] = []

    private var hiders: Set<UUID> = []

    var tag: Tag? { registrations.last?.tag }

    /// True while a screen that has its own bottom controls (a thought) is on screen.
    var hidesButton: Bool { !hiders.isEmpty }

    func hideButton(token: UUID) { hiders.insert(token) }

    func showButton(token: UUID) { hiders.remove(token) }

    func register(token: UUID, tag: Tag) {
        registrations.removeAll { $0.token == token }
        registrations.append((token, tag))
    }

    func unregister(token: UUID) {
        registrations.removeAll { $0.token == token }
    }
}
