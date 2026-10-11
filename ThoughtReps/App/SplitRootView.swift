import SwiftUI

/// The regular-width layout: sections in the sidebar, the section's list in the content column, and the
/// selected thought in the detail column. Compact widths use the tab bar in `RootTabView` instead.
struct SplitRootView: View {
    let onCapture: (_ prefillTag: String?) -> Void

    @Environment(ThoughtSelection.self) private var selection: ThoughtSelection?
    @State private var navigation = AppNavigation.shared
    /// Each section keeps its own pushed screens (a tag's timeline, search) while another is selected.
    @State private var paths = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, NavigationPath()) })

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            content
        } detail: {
            ThoughtDetailColumn()
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection?.pendingTag) { _, tag in
            guard let tag else { return }
            selection?.pendingTag = nil
            paths[navigation.selectedTab, default: NavigationPath()].append(tag)
        }
        .onChange(of: navigation.searchRequestCount) {
            paths[.timeline] = NavigationPath([SearchRoute()])
        }
    }

    private var sidebar: some View {
        List(AppTab.allCases, id: \.self, selection: Binding<AppTab?>(
            get: { navigation.selectedTab },
            set: { if let tab = $0 { navigation.selectedTab = tab } }
        )) { tab in
            Label(tab.title, systemImage: tab.systemImage)
                .font(.archivo(17, relativeTo: .body))
                .foregroundStyle(Color.ink)
        }
        .scrollContentBackground(.hidden)
        .background(Color.paper)
        .navigationTitle("Thought Reps")
    }

    private var content: some View {
        let tab = navigation.selectedTab
        return NavigationStack(path: Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 })) {
            root(of: tab)
                .thoughtDestinations()
        }
        .id(tab)
        .overlay(alignment: .bottomTrailing) {
            CaptureOverlay(bottomInset: 20, onCapture: onCapture)
        }
        .navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 520)
    }

    @ViewBuilder
    private func root(of tab: AppTab) -> some View {
        switch tab {
        case .timeline: ThoughtTimelineView()
        case .tags: TagListView()
        case .archive: ArchiveView()
        case .stats: StatsView()
        }
    }
}
