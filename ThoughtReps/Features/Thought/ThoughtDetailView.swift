import SwiftUI
import SwiftData

/// Full view of one thought. Opening it counts as a view (unless archived).
struct ThoughtDetailView: View {
    let thought: Thought

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.defaultIntervalDays) private var defaultIntervalDays = Scheduler.defaultIntervalDays

    @State private var hasRecordedView = false
    @State private var isEditing = false
    @State private var isPickingInterval = false
    @State private var confirmDelete = false
    @State private var pendingDelete = false

    private var store: ThoughtStore {
        ThoughtStore(context: context, defaultIntervalDays: defaultIntervalDays)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !thought.sortedTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        TagChips(tags: thought.sortedTags, linked: true)
                    }
                }
                ThoughtRenderer(markdown: thought.body)
                ForEach(thought.sortedBlocks) { block in
                    BlockView(block: block)
                }
                Divider().padding(.top, 8)
                footer
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(.bottom, 88, for: .scrollContent) // room for the + button
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isEditing) {
            EditorView(mode: .edit(thought))
        }
        .confirmationDialog("Delete this thought?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteThought)
        } message: {
            Text("This can't be undone.")
        }
        .onAppear { recordView() }
        .onDisappear {
            // Delete only once the pop has finished, so this view never renders a deleted model.
            if pendingDelete {
                pendingDelete = false
                store.delete(thought)
            }
        }
    }

    // MARK: Pieces

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            if !thought.isArchived {
                intervalMenu
            }
        }
    }

    private var statusText: String {
        if thought.isArchived {
            let date = thought.archivedAt ?? thought.updatedAt
            return "Archived \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        let back = thought.isPinned ? "Pinned" : "Back \(RelativeDay.phrase(for: thought.nextDueAt, now: .now))"
        let views = thought.viewCount == 1 ? "1 view" : "\(thought.viewCount) views"
        return "\(back) · \(views)"
    }

    private var intervalMenu: some View {
        let selection = Binding<Int?>(
            get: { thought.intervalDays },
            set: { store.setInterval(thought, days: $0, now: .now) }
        )
        let current = IntervalDuration(days: thought.effectiveIntervalDays(defaultDays: defaultIntervalDays))
        return Menu {
            Picker("Interval", selection: selection) {
                Text("Default (\(defaultIntervalDays) days)").tag(Int?.none)
                ForEach(IntervalOption.choices(including: thought.intervalDays), id: \.self) { days in
                    Text(IntervalDuration(days: days).label).tag(Int?.some(days))
                }
            }
            .pickerStyle(.inline)
            Button("Custom…") { isPickingInterval = true }
        } label: {
            Text("Every \(current.phrase)")
                .font(.footnote.weight(.semibold))
        }
        .sheet(isPresented: $isPickingInterval) {
            IntervalPickerSheet(
                initialDays: thought.effectiveIntervalDays(defaultDays: defaultIntervalDays)
            ) { days in
                if thought.intervalDays == nil && days == defaultIntervalDays { return }
                store.setInterval(thought, days: days, now: .now)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !thought.isArchived {
                Button {
                    store.setPinned(thought, !thought.isPinned)
                } label: {
                    Image(systemName: thought.isPinned ? "pin.fill" : "pin")
                }
                .accessibilityLabel(thought.isPinned ? "Unpin" : "Pin")
            }
            Button("Edit") { isEditing = true }
            Menu {
                if thought.isArchived {
                    Button {
                        store.restore(thought, now: .now)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        store.snooze(thought, days: 1, now: .now)
                        dismiss()
                    } label: {
                        Label("Snooze until tomorrow", systemImage: "moon.zzz")
                    }
                    Button {
                        store.snooze(thought, days: 7, now: .now)
                        dismiss()
                    } label: {
                        Label("Snooze a week", systemImage: "calendar")
                    }
                    Button {
                        store.archive(thought, now: .now)
                        dismiss()
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    // MARK: Actions

    private func recordView() {
        guard !hasRecordedView, !thought.isArchived else { return }
        hasRecordedView = true
        store.markViewed(thought, now: .now)
    }

    private func deleteThought() {
        pendingDelete = true
        dismiss()
    }
}
