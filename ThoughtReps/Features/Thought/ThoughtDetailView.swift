import SwiftUI
import SwiftData

/// Full view of one thought. Opening it counts as a view (unless archived).
struct ThoughtDetailView: View {
    let thought: Thought

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(CaptureContext.self) private var captureContext: CaptureContext?
    @Environment(ThoughtSelection.self) private var selection: ThoughtSelection?
    @AppStorage(AppSettings.Key.defaultIntervalDays) private var defaultIntervalDays = Scheduler.defaultIntervalDays

    @State private var hasRecordedView = false
    @State private var isPickingInterval = false
    @State private var confirmDelete = false
    @State private var pendingDelete = false
    @State private var tappedTag: Tag?
    @State private var viewingImage: ImageViewerStart?
    @State private var captureToken = UUID()

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
                let parts = ThoughtTitleSplit.split(thought.body)
                if let parts {
                    Text(parts.title)
                        .font(.archivo(30, weight: .bold, relativeTo: .largeTitle))
                        .tracking(-0.5)
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 16) {
                    ThoughtRenderer(markdown: parts?.rest ?? thought.body, images: thought.images ?? []) { viewingImage = ImageViewerStart(id: $0) }
                    ForEach(thought.sortedBlocks) { block in
                        BlockView(block: block, images: thought.images ?? []) { viewingImage = ImageViewerStart(id: $0) }
                    }
                }
                .environment(\.openURL, OpenURLAction(handler: openLink))
                Divider().padding(.top, 8)
                footer
            }
            .padding(20)
            .frame(maxWidth: ReadableWidth.column, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.paper)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !thought.isArchived {
                intervalBar
            }
        }
        .sheet(isPresented: $isPickingInterval) {
            IntervalPickerSheet(
                initialDays: thought.effectiveIntervalDays(defaultDays: defaultIntervalDays)
            ) { days in
                if thought.intervalDays == nil && days == defaultIntervalDays { return }
                store.setInterval(thought, days: days, now: .now)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .imageViewer(item: $viewingImage, images: { thought.orderedImages })
        .navigationDestination(item: $tappedTag) { TagTimelineView(tag: $0) }
        .confirmationDialog("Delete this thought?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteThought)
        } message: {
            Text("This can't be undone.")
        }
        .onAppear {
            recordView()
            // The interval bar takes the bottom edge. In the split view the + sits in the list column, clear of it.
            if selection == nil { captureContext?.hideButton(token: captureToken) }
        }
        .onDisappear {
            captureContext?.showButton(token: captureToken)
            // Delete only once the pop has finished, so this view never renders a deleted model.
            if pendingDelete {
                pendingDelete = false
                store.delete(thought, now: .now)
            }
        }
    }

    // MARK: Pieces

    private var footer: some View {
        Text(statusText)
            .font(.mono(12, relativeTo: .footnote))
            .foregroundStyle(Color.muted)
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

    private static let quickIntervals = [1, 3, 7, 30]

    private var isLearning: Bool { thought.intervalMode == .learn }

    private var intervalBar: some View {
        let current = thought.effectiveIntervalDays(defaultDays: defaultIntervalDays)
        let now = Date.now
        let showsReview = isLearning && !thought.isPinned && thought.isDue(now: now)
        return VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(headerText(now: now))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if !isLearning, !thought.isPinned {
                    Text("next: \(thought.nextDueAt.formatted(.dateTime.month(.abbreviated).day()))")
                }
                Toggle("Learn", isOn: learnBinding)
                    .controlSize(.small)
                    .tint(Color.ink)
                    .fixedSize()
                    .accessibilityLabel("Learn mode")
            }
            .font(.mono(12, relativeTo: .footnote))
            .foregroundStyle(Color.muted)
            if showsReview {
                HStack(spacing: 8) {
                    reviewButton("Again", gotIt: false, now: now)
                    reviewButton("Got it", gotIt: true, now: now)
                }
            } else if !isLearning {
                HStack(spacing: 8) {
                    ForEach(Self.quickIntervals, id: \.self) { days in
                        Button {
                            store.setInterval(thought, days: days, now: .now)
                        } label: {
                            intervalChip("\(days)d", selected: current == days)
                        }
                        .buttonStyle(InkPressStyle(cornerRadius: 10, pressedScale: 0.94))
                        .accessibilityLabel(IntervalDuration(days: days).label)
                        .accessibilityAddTraits(current == days ? .isSelected : [])
                    }
                    intervalMenu(selected: !Self.quickIntervals.contains(current))
                }
            }
        }
        .sensoryFeedback(.selection, trigger: current)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: ReadableWidth.controls)
        .frame(maxWidth: .infinity)
        .background(Color.paper)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.hl).frame(height: 1)
        }
    }

    private var learnBinding: Binding<Bool> {
        Binding(
            get: { isLearning },
            set: { store.setLearnMode(thought, $0, now: .now) }
        )
    }

    private func headerText(now: Date) -> String {
        guard isLearning else { return "Back in" }
        if thought.isPinned { return "Pinned · not reviewed" }
        if thought.isDue(now: now) { return "How did it go?" }
        return "Back \(RelativeDay.phrase(for: thought.nextDueAt, now: now))"
    }

    private func reviewButton(_ title: String, gotIt: Bool, now: Date) -> some View {
        let gap = Scheduler.afterReview(
            gotIt: gotIt,
            lastGapDays: thought.learnIntervalDays,
            baseIntervalDays: thought.effectiveIntervalDays(defaultDays: defaultIntervalDays),
            now: now
        ).learnIntervalDays ?? 1
        let preview = gap == 1 ? "Tomorrow" : "In \(gap) days"
        return Button {
            store.review(thought, gotIt: gotIt, now: .now)
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.mono(13, semibold: true, relativeTo: .footnote))
                Text(preview)
                    .font(.mono(11, relativeTo: .caption))
                    .opacity(0.7)
            }
            .foregroundStyle(gotIt ? Color.paper : Color.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 10).fill(gotIt ? Color.ink : Color.paper))
            .overlay {
                if !gotIt {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hl, lineWidth: 1)
                }
            }
        }
        .buttonStyle(InkPressStyle(cornerRadius: 10, pressedScale: 0.96))
        .accessibilityLabel("\(title), back \(preview.lowercased())")
    }

    private func intervalChip(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.mono(13, semibold: true, relativeTo: .footnote))
            .foregroundStyle(selected ? Color.paper : Color.ink)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.ink : Color.paper))
            .overlay {
                if !selected {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.hl, lineWidth: 1)
                }
            }
    }

    private func intervalMenu(selected: Bool) -> some View {
        let selection = Binding<Int?>(
            get: { thought.intervalDays },
            set: { store.setInterval(thought, days: $0, now: .now) }
        )
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
            intervalChip("…", selected: selected)
        }
        .accessibilityLabel("More intervals")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !thought.isArchived {
                Button {
                    store.setPinned(thought, !thought.isPinned, now: .now)
                } label: {
                    Image(systemName: thought.isPinned ? "pin.fill" : "pin")
                }
                .accessibilityLabel(thought.isPinned ? "Unpin" : "Pin")
            }
            Button("Edit") { AppNavigation.shared.requestEdit(thoughtID: thought.id) }
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
                        leave()
                    } label: {
                        Label("Snooze until tomorrow", systemImage: "moon.zzz")
                    }
                    Button {
                        store.snooze(thought, days: 7, now: .now)
                        leave()
                    } label: {
                        Label("Snooze a week", systemImage: "calendar")
                    }
                    Button {
                        store.archive(thought, now: .now)
                        leave()
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

    private func openLink(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == TagLinker.scheme else { return .systemAction }
        guard let key = TagLinker.key(from: url),
              let tag = thought.sortedTags.first(where: { $0.name == key }) else { return .discarded }
        if let selection {
            selection.pendingTag = tag
        } else {
            tappedTag = tag
        }
        return .handled
    }

    /// Pops this thought off the stack, or clears the split view's detail column.
    private func leave() {
        if let selection { selection.clear() } else { dismiss() }
    }

    private func deleteThought() {
        pendingDelete = true
        leave()
    }
}
