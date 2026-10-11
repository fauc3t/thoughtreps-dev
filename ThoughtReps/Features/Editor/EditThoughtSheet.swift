import SwiftUI
import SwiftData

/// The editor for an `AppNavigation.editRequest`, looked up by id so a thought deleted meanwhile closes the sheet.
struct EditThoughtSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var matches: [Thought]

    init(thoughtID: UUID) {
        var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { $0.id == thoughtID })
        descriptor.fetchLimit = 1
        _matches = Query(descriptor)
    }

    var body: some View {
        if let thought = matches.first {
            EditorView(mode: .edit(thought))
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}
