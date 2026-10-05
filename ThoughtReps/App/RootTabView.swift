import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var context
    @State private var captureContext = CaptureContext()
    @State private var isCapturing = false
    @State private var saveErrors = SaveErrorCenter.shared
    @State private var navigation = AppNavigation.shared
    @State private var prefillTag: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            NavigationStack {
                ThoughtTimelineView()
                    .thoughtDestinations()
            }
            .tabItem { Label("Timeline", systemImage: "text.alignleft") }
            .tag(AppTab.timeline)

            NavigationStack {
                TagListView()
                    .thoughtDestinations()
            }
            .tabItem { Label("Tags", systemImage: "number") }
            .tag(AppTab.tags)

            NavigationStack {
                ArchiveView()
                    .thoughtDestinations()
            }
            .tabItem { Label("Archive", systemImage: "archivebox") }
            .tag(AppTab.archive)
        }
        .environment(captureContext)
        .overlay(alignment: .bottomTrailing) {
            CaptureButton(hasTag: captureContext.tag != nil) {
                prefillTag = captureContext.tag?.displayName
                isCapturing = true
            }
                .padding(.trailing, 20)
                .padding(.bottom, 66) // clears the tab bar
        }
        .sheet(isPresented: $isCapturing) {
            EditorView(mode: .new(prefillTag: prefillTag))
        }
        .saveErrorAlert(saveErrors)
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                Task { await NotificationScheduler.reschedule(context: context, now: .now) }
            case .background:
                let assertion = BackgroundAssertion()
                Task {
                    await NotificationScheduler.reschedule(context: context, now: .now)
                    assertion.end()
                }
            default:
                break
            }
        }
        .task {
            ThoughtStore(context: context).pruneOrphanTags()
            #if DEBUG
            SampleData.seedIfNeeded(context: context)
            IntegrityChecker.logViolations(in: context)
            #endif
        }
    }
}

/// Keeps the app running briefly after it backgrounds; `end()` is safe to call more than once.
@MainActor
private final class BackgroundAssertion {
    private var id = UIBackgroundTaskIdentifier.invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// The floating "+" that opens the editor from any tab.
struct CaptureButton: View {
    var hasTag = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: Color.accentColor.opacity(0.35), radius: 8, y: 4)
        }
        .accessibilityLabel(hasTag ? "New thought with this tag" : "New thought")
    }
}

#Preview {
    RootTabView()
        .modelContainer(PreviewData.container)
}
