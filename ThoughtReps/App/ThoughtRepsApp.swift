import SwiftUI
import SwiftData

@main
struct ThoughtRepsApp: App {
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(for: [Thought.self, Tag.self, Block.self, ImageAsset.self])
    }
}
