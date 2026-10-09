import SwiftUI
import UserNotifications
import SwiftData

private struct CaptureRequest: Identifiable {
    let id = UUID()
    let prefillTag: String?
}

struct RootTabView: View {
    @Environment(\.modelContext) private var context
    @State private var captureContext = CaptureContext()
    @State private var capture: CaptureRequest?
    @State private var createdThought = false
    @State private var showReminderPrompt = false
    @State private var saveErrors = SaveErrorCenter.shared
    @State private var navigation = AppNavigation.shared
    @State private var inboxImporter = InboxImporter()
    @State private var backup = BackupModel.shared
    @Environment(\.scenePhase) private var scenePhase

    private func importInbox() {
        guard let inbox = try? Inbox.directoryURL() else { return }
        inboxImporter.importPending(from: inbox, store: ThoughtStore(context: context))
    }

    private func open(_ url: URL) {
        if url.isFileURL {
            backup.beginImport(from: url, container: context.container)
        } else if ExportLinkImportModel.handles(url) {
            Task { await ExportLinkImportModel.shared.present(opening: url) }
        }
    }

    /// Runs after the editor sheet is gone so the prompt never stacks on it.
    private func offerReminders() {
        guard createdThought else { return }
        createdThought = false
        Task {
            let prompt = ReminderPrompt()
            guard prompt.shouldOffer(status: await NotificationScheduler.authorizationStatus()) else { return }
            showReminderPrompt = true
        }
    }

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

            NavigationStack {
                StatsView()
                    .thoughtDestinations()
            }
            .tabItem { Label("Stats", systemImage: "chart.bar") }
            .tag(AppTab.stats)
        }
        .environment(captureContext)
        .overlay(alignment: .bottomTrailing) {
            CaptureButton(hasTag: captureContext.tag != nil) {
                capture = CaptureRequest(prefillTag: captureContext.tag?.displayName)
            }
                .padding(.trailing, 20)
                .padding(.bottom, 66) // clears the tab bar
                .opacity(captureContext.hidesButton ? 0 : 1)
                .allowsHitTesting(!captureContext.hidesButton)
                .accessibilityHidden(captureContext.hidesButton)
                .animation(.easeOut(duration: 0.2), value: captureContext.hidesButton)
        }
        .sheet(item: $capture, onDismiss: offerReminders) { request in
            EditorView(mode: .new(prefillTag: request.prefillTag), onCreated: { createdThought = true })
        }
        .sheet(isPresented: $showReminderPrompt) {
            ReminderPromptSheet()
        }
        .saveErrorAlert(saveErrors)
        .backupImportSheet(backup, host: .root)
        .onOpenURL(perform: open)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { open(url) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            #if DEBUG
            if ScreenshotMode.isActive { return }
            #endif
            switch phase {
            case .active:
                importInbox()
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
            backup.removeStaleTemporaryFiles()
            ThoughtStore(context: context).pruneOrphanTags()
            ThoughtStore(context: context).migrateLegacyBlurredBlocks()
            ThoughtStore(context: context).cleanUpPendingImageSaves()
            #if DEBUG
            if !ScreenshotMode.isActive { SampleData.seedIfNeeded(context: context) }
            if ScreenshotMode.sendsTestReminder {
                // Long enough for the UI test to answer the permission alert and lock the device first:
                // a notification that arrives while the app is open isn't shown.
                // Last run's notification would stack under this one on the Lock Screen.
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                Task { _ = await NotificationScheduler.sendTestReminder(context: context, now: .now, delay: 15) }
            }
            IntegrityChecker.logViolations(in: context)
            #endif
            await SearchIndexStatus.shared.reconcile(container: context.container)
            #if DEBUG
            await SearchIndexChecker.logViolations(in: context)
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
    @State private var pressCount = 0

    var body: some View {
        Button {
            pressCount += 1
            action()
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.paper)
                .frame(width: 56, height: 56)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(Color.hl).offset(x: 3, y: 3)
                        RoundedRectangle(cornerRadius: 16).fill(Color.ink)
                    }
                }
        }
        .buttonStyle(InkPressStyle(cornerRadius: 16, pressedScale: 0.92))
        .sensoryFeedback(.impact(weight: .light), trigger: pressCount)
        .accessibilityLabel(hasTag ? "New thought with this tag" : "New thought")
    }
}

#Preview {
    RootTabView()
        .modelContainer(PreviewData.container)
}
