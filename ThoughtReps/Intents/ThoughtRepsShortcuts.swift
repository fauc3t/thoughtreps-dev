import AppIntents

struct ThoughtRepsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewThoughtIntent(),
            phrases: [
                "New thought in \(.applicationName)",
                "Write a thought in \(.applicationName)",
            ],
            shortTitle: "New Thought",
            systemImageName: "square.and.pencil"
        )
    }
}
