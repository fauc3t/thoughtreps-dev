import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.modelContext) private var context
    @State private var isCapturing = false

    var body: some View {
        TabView {
            NavigationStack {
                ThoughtTimelineView()
                    .thoughtDestinations()
            }
            .tabItem { Label("Timeline", systemImage: "text.alignleft") }

            NavigationStack {
                TagListView()
                    .thoughtDestinations()
            }
            .tabItem { Label("Tags", systemImage: "number") }

            NavigationStack {
                ArchiveView()
                    .thoughtDestinations()
            }
            .tabItem { Label("Archive", systemImage: "archivebox") }
        }
        .overlay(alignment: .bottomTrailing) {
            CaptureButton { isCapturing = true }
                .padding(.trailing, 20)
                .padding(.bottom, 66) // clears the tab bar
        }
        .sheet(isPresented: $isCapturing) {
            EditorView(mode: .new())
        }
        .task {
            ThoughtStore(context: context).pruneOrphanTags()
            #if DEBUG
            SampleData.seedIfNeeded(context: context)
            #endif
        }
    }
}

/// The floating "+" that opens the editor from any tab.
struct CaptureButton: View {
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
        .accessibilityLabel("New thought")
    }
}

#Preview {
    RootTabView()
        .modelContainer(PreviewData.container)
}
