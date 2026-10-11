/// Lets one save run at a time: the Save button and the keyboard shortcut can both fire for one key press.
/// A failed save reopens the gate so the draft can be retried; a successful one stays shut while the editor closes.
struct SaveGate {
    private var isSaving = false

    mutating func begin() -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        return true
    }

    mutating func fail() {
        isSaving = false
    }
}
