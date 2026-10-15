import SwiftUI
import SwiftData

/// The editor for an `AppNavigation.editRequest`, looked up by id. The thought found first is kept, so one deleted
/// on another device while the sheet is open leaves the editor (and its drafts) in place: Save then keeps them as a
/// new thought. A thought that was never found closes the sheet.
struct EditThoughtSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var matches: [Thought]
    @State private var held: Thought?

    init(thoughtID: UUID) {
        var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { $0.id == thoughtID })
        descriptor.fetchLimit = 1
        _matches = Query(descriptor)
    }

    /// The thought to edit: the one already held, else the one found now.
    static func resolve<Value>(held: Value?, found: Value?) -> Value? { held ?? found }

    var body: some View {
        if let thought = Self.resolve(held: held, found: matches.first) {
            EditorView(mode: .edit(thought))
                .onAppear { held = thought }
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}
