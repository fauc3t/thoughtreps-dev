import SwiftUI
import SwiftData
import StoreKit

enum TimelineScope {
    case all
    case tag(Tag)
    case untagged

    var queryScope: ThoughtCounts.Scope {
        switch self {
        case .all: .all
        case .tag(let tag): .tag(tag.name)
        case .untagged: .untagged
        }
    }
}

/// The main timeline (pinned + due thoughts). Pass a `scope` to get a tag's or the untagged
/// timeline, which adds a Due / All toggle.
struct ThoughtTimelineView: View {
    var scope: TimelineScope = .all

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @Environment(CaptureContext.self) private var captureContext: CaptureContext?
    @State private var captureToken = UUID()

    /// "Now" as of the last time this screen appeared. Thoughts viewed after it stay listed
    /// until you come back, so a card doesn't vanish while you're reading it.
    @State private var snapshot = Date.now
    @State private var showAll = false
    @State private var showSettings = false
    @State private var showColorSheet = false
    @State private var navigation = AppNavigation.shared

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

    var body: some View {
        TimelineList(scope: scope, showAll: showAll, snapshot: snapshot) { snapshot = .now }
            .navigationTitle(title)
            .toolbar { toolbarContent }
            .onAppear {
                snapshot = .now
                if let tag { captureContext?.register(token: captureToken, tag: tag) }
            }
            .task(id: scenePhase) { await requestReviewIfPending() }
            .onDisappear {
                captureContext?.unregister(token: captureToken)
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
            .sheet(isPresented: $showColorSheet) {
                if let tag { TagColorSheet(tag: tag) }
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
            if tag != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showColorSheet = true
                    } label: {
                        Image(systemName: "paintpalette")
                    }
                    .accessibilityLabel("Change Color")
                }
            }
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
}

/// The rows. Its query is built from the scope and snapshot, so a new snapshot re-creates the view
/// and loads only the pinned and due (or viewed-since) thoughts rather than every active one.
private struct TimelineList: View {
    let scope: TimelineScope
    let showAll: Bool
    let snapshot: Date
    let onRefresh: () -> Void

    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.Key.defaultIntervalDays) private var defaultIntervalDays = Scheduler.defaultIntervalDays
    @Query private var shown: [Thought]
    /// Bumped on every save. The empty state and "come back" text come from queries run in `body`, which
    /// `shown` alone doesn't invalidate (a first thought that isn't due yet, a snooze).
    @State private var saveToken = 0

    init(scope: TimelineScope, showAll: Bool, snapshot: Date, onRefresh: @escaping () -> Void) {
        self.scope = scope
        self.showAll = showAll
        self.snapshot = snapshot
        self.onRefresh = onRefresh
        _shown = Query(
            filter: ThoughtCounts.timeline(scope.queryScope, showAll: showAll, snapshot: snapshot),
            sort: \Thought.nextDueAt
        )
    }

    private var store: ThoughtStore {
        ThoughtStore(context: context, defaultIntervalDays: defaultIntervalDays)
    }

    var body: some View {
        let _ = saveToken
        let pinned = shown.filter(\.isPinned)
        let listed = shown.filter { !$0.isPinned }
        List {
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { row($0) }
                } header: {
                    Text("Pinned").inkSectionHeader()
                }
            }
            if !listed.isEmpty {
                Section {
                    ForEach(listed) { row($0) }
                } header: {
                    Text(showAll ? "All" : "Due").inkSectionHeader()
                }
            } else if !pinned.isEmpty {
                Section {
                    Text(nextUpText)
                        .font(.mono(12))
                        .foregroundStyle(Color.muted)
                        .inkRow()
                } header: {
                    Text("Due").inkSectionHeader()
                }
            }
        }
        .inkList()
        .contentMargins(.bottom, 88, for: .scrollContent) // room for the + button
        .overlay {
            if shown.isEmpty {
                emptyState
            }
        }
        .refreshable { @MainActor in onRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in saveToken += 1 }
    }

    private func row(_ thought: Thought) -> some View {
        NavigationLink(value: thought) {
            ThoughtCard(thought: thought, now: snapshot)
        }
        .inkRow()
        .swipeActions(edge: .leading) {
            Button {
                store.setPinned(thought, !thought.isPinned)
            } label: {
                Label(thought.isPinned ? "Unpin" : "Pin", systemImage: thought.isPinned ? "pin.slash" : "pin")
            }
            .tint(ThemeManager.shared.current.swipe.pin)
        }
        .swipeActions(edge: .trailing) {
            Button {
                store.archive(thought, now: .now)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(ThemeManager.shared.current.swipe.archive)
            if thought.isPinned {
                Button {
                    store.setPinned(thought, false)
                } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
                .tint(ThemeManager.shared.current.swipe.pin)
            } else {
                Button {
                    store.snooze(thought, days: 1, now: .now)
                } label: {
                    Label("Tomorrow", systemImage: "moon.zzz")
                }
                .tint(ThemeManager.shared.current.swipe.tomorrow)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if ThoughtCounts.count(ThoughtCounts.active(scope.queryScope), in: context, limit: 1) == 0 {
            ContentUnavailableView {
                Label("No thoughts yet", systemImage: "lightbulb")
                    .font(.archivo(22, weight: .bold, relativeTo: .title2))
            } description: {
                Group {
                    switch scope {
                    case .all:
                        Text("Tap + to capture your first thought.")
                    case .tag(let tag):
                        Text("Thoughts tagged #\(tag.displayName) show up here.")
                    case .untagged:
                        Text("Thoughts without a tag show up here.")
                    }
                }
                .font(.mono(13, relativeTo: .footnote))
            }
        } else {
            ContentUnavailableView {
                Label("All caught up", systemImage: "checkmark.circle")
                    .font(.archivo(22, weight: .bold, relativeTo: .title2))
            } description: {
                Text(nextUpText)
                    .font(.mono(13, relativeTo: .footnote))
            }
        }
    }

    /// "3 thoughts come back tomorrow."
    private var nextUpText: String {
        guard let (next, count) = ThoughtCounts.nextUp(scope.queryScope, in: context) else { return "Nothing else is scheduled." }
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
