import Observation

/// What the floating "+" should capture into. A tag's timeline sets `tag` while it's on screen.
@Observable
final class CaptureContext {
    var tag: Tag?
}
