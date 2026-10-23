import SwiftUI
import SwiftData

/// The sheet for an `AppNavigation.resolveRequest`, looked up by id. A copy that is gone (resolved, or deleted
/// elsewhere) closes the sheet.
struct ConflictResolveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var matches: [Thought]

    init(copyID: UUID) {
        var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { $0.id == copyID })
        descriptor.fetchLimit = 1
        _matches = Query(descriptor)
    }

    var body: some View {
        if let copy = matches.first, let originalID = copy.conflictOfID {
            ConflictResolveContent(copy: copy, originalID: originalID)
        } else {
            Color.clear.onAppear { dismiss() }
        }
    }
}

private struct ConflictResolveContent: View {
    let copy: Thought

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(ThoughtSelection.self) private var selection: ThoughtSelection?
    @AppStorage(AppSettings.Key.defaultIntervalDays) private var defaultIntervalDays = Scheduler.defaultIntervalDays
    @Query private var originals: [Thought]
    @State private var confirmation: Confirmation?
    @State private var isResolving = false
    @State private var note: String?
    @State private var saveErrors = SaveErrorCenter()

    private enum Confirmation {
        case keepOriginal, delete
    }

    init(copy: Thought, originalID: UUID) {
        self.copy = copy
        var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { $0.id == originalID })
        descriptor.fetchLimit = 1
        _originals = Query(descriptor)
    }

    private var store: ThoughtStore {
        var store = ThoughtStore(context: context, defaultIntervalDays: defaultIntervalDays)
        store.saveErrors = saveErrors
        return store
    }

    private var original: Thought? { originals.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let note {
                        Text(note)
                            .font(.mono(12, relativeTo: .footnote))
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .inkCard(filled: true)
                    }
                    if let original {
                        if horizontalSizeClass == .regular {
                            HStack(alignment: .top, spacing: 24) {
                                copyPanel
                                originalPanel(original)
                            }
                        } else {
                            copyPanel
                            originalPanel(original)
                        }
                        Button("Keep both") { resolve(failure: "Couldn't keep both.") { store.keepBoth(copy, now: .now) } }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Original deleted")
                            .font(.mono(12, relativeTo: .footnote))
                            .foregroundStyle(Color.muted)
                        copyPanel
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .disabled(isResolving)
            .background(Color.paper)
            .navigationTitle("Needs a look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .saveErrorAlert(saveErrors)
        }
    }

    private var copyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConflictVersion(label: original == nil ? "Copy" : "This version", thought: copy)
            if original == nil {
                Button("Keep") { resolve(failure: "Couldn't keep this thought.") { store.keepBoth(copy, now: .now) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("Delete", role: .destructive) { confirmation = .delete }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .confirmationDialog("Delete this thought?", isPresented: isConfirming(.delete), titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { confirmed(.delete) }
                    } message: {
                        Text("This can't be undone.")
                    }
            } else {
                Button("Keep this version") {
                    resolve(leaving: true, failure: "Couldn't keep this version. The original may be gone, or the copy's files can't be read.") { store.keepCopy(copy, now: .now) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Each confirmation hangs off its own button so it opens next to it.
    private func isConfirming(_ choice: Confirmation) -> Binding<Bool> {
        Binding(get: { confirmation == choice }, set: { if !$0 { confirmation = nil } })
    }

    private func originalPanel(_ original: Thought) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ConflictVersion(label: "Original", thought: original)
            Button("Keep the original", role: .destructive) { confirmation = .keepOriginal }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .confirmationDialog("Delete the copy?", isPresented: isConfirming(.keepOriginal), titleVisibility: .visible) {
                    Button("Keep the original", role: .destructive) { confirmed(.keepOriginal) }
                } message: {
                    Text("This can't be undone.")
                }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func confirmed(_ choice: Confirmation) {
        switch choice {
        case .keepOriginal: resolve(leaving: true, failure: "Couldn't delete the copy.") { store.keepOriginal(copy, now: .now) }
        case .delete: resolve(leaving: true, failure: "Couldn't delete this thought.") { store.delete(copy, now: .now) }
        }
    }

    /// Closes only when the write succeeded. A false return with no save error raised (the store refused without
    /// saving) shows `failure` inline instead. `leaving` is for writes that delete the copy: the split view's
    /// detail column lets go of it once they succeed.
    private func resolve(leaving: Bool = false, failure: String, _ write: () -> Bool) {
        guard !isResolving else { return }
        isResolving = true
        note = nil
        saveErrors.dismiss()
        if write() {
            if leaving { selection?.clear(ifSelected: copy) }
            dismiss()
            return
        }
        isResolving = false
        if saveErrors.message == nil { note = failure }
    }
}

/// One version of a thought, read-only: its date, title, text and blocks.
private struct ConflictVersion: View {
    let label: String
    let thought: Thought

    var body: some View {
        let parts = ThoughtTitleSplit.split(thought.body)
        VStack(alignment: .leading, spacing: 12) {
            Text("\(label) · edited \(thought.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.mono(12, relativeTo: .footnote))
                .foregroundStyle(Color.muted)
            VStack(alignment: .leading, spacing: 12) {
                if let parts {
                    Text(parts.title)
                        .font(.archivo(22, weight: .bold, relativeTo: .title2))
                        .foregroundStyle(Color.ink)
                }
                ThoughtRenderer(markdown: parts?.rest ?? thought.body, images: thought.images ?? [])
                ForEach(thought.sortedBlocks.filter { $0.kind != .thoughtLink }) { block in
                    BlockView(block: block, images: thought.images ?? [], onOpenImage: { _ in })
                }
            }
            .environment(\.openURL, OpenURLAction { _ in .handled })
            .frame(maxWidth: .infinity, alignment: .leading)
            .inkCard()
        }
    }
}
