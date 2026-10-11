import Foundation

/// The open editor's save and cancel, for the ⌘↩ and Esc key commands of its text views. Only one
/// editor is ever on screen, so it registers on appear and clears on disappear.
@MainActor
final class EditorShortcuts {
    static let shared = EditorShortcuts()

    private(set) var save: () -> Void = {}
    private(set) var cancel: () -> Void = {}

    func open(save: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.save = save
        self.cancel = cancel
    }

    func close() {
        save = {}
        cancel = {}
    }
}
