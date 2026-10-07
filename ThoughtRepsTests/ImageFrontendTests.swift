import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Image frontend")
struct ImageFrontendTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let container: ModelContainer
    let context: ModelContext
    let store: ThoughtStore

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        context = container.mainContext
        store = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
    }

    @Test func providerNeverResolvesNonImageURLs() async {
        let library = ImageLibrary()
        let provider = LocalImageProvider(library: library, onOpen: { _ in })
        for text in ["http://example.com/a.png", "https://example.com/a.png", "file:///tmp/a.png", "img:nope"] {
            await #expect(throws: (any Error).self, "\(text)") {
                _ = try await provider.image(with: URL(string: text)!, label: "")
            }
        }
    }

    @Test func providerRendersNothingForMissingIDs() async {
        let provider = LocalImageProvider(library: ImageLibrary(), onOpen: { _ in })
        await #expect(throws: (any Error).self) {
            _ = try await provider.image(with: URL(string: "img:\(UUID().uuidString)")!, label: "")
        }
    }

    @Test func existingGalleryImagesMapToExistingDrafts() throws {
        let thought = store.create(
            body: "Body",
            blocks: [
                BlockDraft(title: "Hidden", content: "Secret"),
                BlockDraft(kind: .gallery, title: "Board", images: [newImage(1), newImage(2)]),
            ],
            intervalDays: nil,
            now: now
        )
        let drafts = BlockDraft.drafts(for: thought)
        #expect(drafts.count == 2)
        #expect(drafts[0].kind == .markdown && drafts[0].content == "Secret")

        let gallery = try #require(thought.sortedBlocks.last)
        #expect(drafts[1].id == gallery.id)
        #expect(drafts[1].title == "Board")
        #expect(drafts[1].images == gallery.sortedImages.map { ImageDraft(existing: $0) })
        #expect(drafts[1].images.allSatisfy { $0.processed == nil })

        #expect(store.update(thought, body: "Body", blocks: drafts, intervalDays: nil, now: now))
        #expect(gallery.sortedImages.count == 2)
    }
}
