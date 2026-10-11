import SwiftUI
import SwiftData

@main
struct ThoughtRepsApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private static let container = Result { try makeContainer() }

    private static func makeContainer() throws -> ModelContainer {
        #if DEBUG
        if ScreenshotMode.isActive { return try ScreenshotMode.makeContainer() }
        #endif
        return try ModelContainer.thoughtReps()
    }

    private let themes = ThemeManager.shared

    init() {
        InkAppearance.install()
    }

    var body: some Scene {
        WindowGroup {
            switch Self.container {
            case .success(let container):
                RootTabView()
                    .modelContainer(container)
                    .tint(Color.accent)
                    .onAppear { themes.applyInterfaceStyle() }
            case .failure(let error):
                StoreUnavailableView(error: error)
            }
        }
        .commands { AppCommands() }
    }
}

/// Shown instead of the app when the store can't be opened. Falling back to an empty store
/// would look like data loss and let new writes diverge from what is on disk.
private struct StoreUnavailableView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView(
            "Couldn't open your thoughts",
            systemImage: "exclamationmark.triangle",
            description: Text("Your data hasn't been changed. Restart the app, and if this keeps happening, update to the latest version.\n\n\(error.localizedDescription)")
        )
    }
}
