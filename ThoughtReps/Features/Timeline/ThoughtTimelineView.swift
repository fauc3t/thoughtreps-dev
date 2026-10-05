import SwiftUI
import SwiftData
import StoreKit

enum TimelineScope {
    case all
    case tag(Tag)
    case untagged
}

/// The main timeline (pinned + due thoughts). Pass a `scope` to get a tag's or the untagged
/// timeline, which adds a Due / All toggle.
struct ThoughtTimelineView: View {
    var scope: TimelineScope = .all

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @Environment(CaptureContext.self) private var captureContext: CaptureContext?
    @AppStorage(AppSettings.Key.defaultIntervalDays) private var defaultIntervalDays = Scheduler.defaultIntervalDays

    @Query(filter: #Predicate<Thought> { $0.isArchived == false }, sort: \Thought.nextDueAt)
    private var active: [Thought]

    /// "Now" as of the last time this screen appeared. Thoughts viewed after it stay listed
    /// until you come back, so a card doesn't vanish while you're reading it.
    @State private var snapshot = Date.now
    @State private var showAll = false
    @State private var showSettings = false
    @State private var navigation = AppNavigation.shared

    private var store: ThoughtStore {
        ThoughtStore(context: context, defaultIntervalDays: defaultIntervalDays)
    }

    private var scoped: [Thought] {
        switch scope {
        case .all:
            return active
        case .tag(let tag):
            let id = tag.persistentModelID
            return active.filter { thought in
                (thought.tags ?? []).contains { $0.persistentModelID == id }
            }
        case .untagged:
            return active.filter(\.isUntagged)
        }
    }

    private var isScoped: Bool {
        if case .all = scope { return false }
        return true
    }

    private var title: String {
        switch scope {
        case .all: "Timeline"
        case .tag(let tag): "#\(tag.displayName)"
        case .untagged: "Untagged"
        }
    }

    private var tag: Tag? {
        if case .tag(let tag) = scope { return tag }
        return nil
    }

    private var pinned: [Thought] {
        scoped.filter(\.isPinned)
    }

    private var listed: [Thought] {
        scoped.filter { thought in
            !thought.isPinned && (showAll || thought.isOnTimeline(now: snapshot))
        }
    }

    var body: some View {
        List {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { row($0) }
                }
            }
            if !listed.isEmpty {
                Section(showAll ? "All" : "Due") {
                    ForEach(listed) { row($0) }
                }
            } else if !pinned.isEmpty {
                Section("Due") {
                    Text(nextUpText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, 88, for: .scrollContent) // room for the + button
        .overlay {
            if pinned.isEmpty && listed.isEmpty {
                emptyState
            }
        }
        .navigationTitle(title)
        .toolbar { toolbarContent }
        .refreshable { @MainActor in snapshot = .now }
        .onAppear {
            snapshot = .now
            if let tag { captureContext?.tag = tag }
        }
        .task(id: scenePhase) { await requestReviewIfPending() }
        .onDisappear {
            if let tag, captureContext?.tag?.persistentModelID == tag.persistentModelID {
                captureContext?.tag = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { snapshot = .now }
        }
        .onChange(of: showAll) {
            snapshot = .now
        }
        .onChange(of: navigation.reminderOpenCount) { showSettings = false }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    /// Runs while the main timeline is on screen. The delay lets a returning navigation or sheet
    /// settle; `.task` cancels if the view leaves, and `pending` stays set so a dropped attempt retries.
    private func requestReviewIfPending() async {
        guard !isScoped, scenePhase == .active else { return }
        let prompt = RatingPrompt()
        guard prompt.isPending, !prompt.wasAsked else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, scenePhase == .active else { return }
        requestReview()
        prompt.markAsked()
    }

    private func row(_ thought: Thought) -> some View {
        NavigationLink(value: thought) {
            ThoughtCard(thought: thought, now: snapshot)
        }
        .swipeActions(edge: .leading) {
            Button {
                store.setPinned(thought, !thought.isPinned)
            } label: {
                Label(thought.isPinned ? "Unpin" : "Pin", systemImage: thought.isPinned ? "pin.slash" : "pin")
            }
            .tint(.accentColor)
        }
        .swipeActions(edge: .trailing) {
            Button {
                store.archive(thought, now: .now)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.gray)
            if thought.isPinned {
                Button {
                    store.setPinned(thought, false)
                } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
                .tint(.accentColor)
            } else {
                Button {
                    store.snooze(thought, days: 1, now: .now)
                } label: {
                    Label("Tomorrow", systemImage: "moon.zzz")
                }
                .tint(.orange)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !isScoped {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SearchView()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        } else {
            if #available(iOS 26, *) {
                ToolbarItem(placement: .topBarTrailing) { showPicker }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { showPicker }
            }
        }
    }

    // The segmented control draws its own glass on iOS 26+, so the toolbar's shared background is hidden there.
    private var showPicker: some View {
        Picker("Show", selection: $showAll) {
            Text("Due").tag(false)
            Text("All").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 120)
    }

    @ViewBuilder
    private var emptyState: some View {
        if scoped.isEmpty {
            ContentUnavailableView {
                Label("No thoughts yet", systemImage: "lightbulb")
            } description: {
                switch scope {
                case .all:
                    Text("Tap + to capture your first thought.")
                case .tag(let tag):
                    Text("Thoughts tagged #\(tag.displayName) show up here.")
                case .untagged:
                    Text("Thoughts without a tag show up here.")
                }
            }
        } else {
            ContentUnavailableView {
                Label("All caught up", systemImage: "checkmark.circle")
            } description: {
                Text(nextUpText)
            }
        }
    }

    /// "3 thoughts come back tomorrow."
    private var nextUpText: String {
        let waiting = scoped.filter { !$0.isPinned }
        guard let next = waiting.map(\.nextDueAt).min() else { return "Nothing else is scheduled." }
        let count = waiting.filter { Calendar.current.isDate($0.nextDueAt, inSameDayAs: next) }.count
        let noun = count == 1 ? "thought comes" : "thoughts come"
        return "\(count) \(noun) back \(RelativeDay.phrase(for: next, now: snapshot))."
    }
}

#Preview {
    NavigationStack {
        ThoughtTimelineView()
            .thoughtDestinations()
    }
    .modelContainer(PreviewData.container)
}
