import SwiftUI

/// Hardware-keyboard shortcuts. They are real commands, so holding ⌘ lists them. Each only asks
/// `AppNavigation` for something; the layout on screen (tabs or split view) acts on it.
struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Thought") { AppNavigation.shared.requestNewThought() }
                .keyboardShortcut("n")
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { AppNavigation.shared.requestSettings() }
                .keyboardShortcut(",")
        }
        // In its own menu: filed under the system Find items, ⌘F never reached this command.
        CommandMenu("Search") {
            Button("Search Thoughts") { AppNavigation.shared.requestSearch() }
                .keyboardShortcut("f")
        }
        CommandGroup(before: .sidebar) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button(tab.title) { AppNavigation.shared.requestTab(tab) }
                    .keyboardShortcut(KeyEquivalent(Character("\(tab.shortcutNumber)")))
            }
        }
    }
}
