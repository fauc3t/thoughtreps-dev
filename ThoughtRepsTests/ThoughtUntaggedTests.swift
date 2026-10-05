import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Thought.isUntagged")
struct ThoughtUntaggedTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func nilTagsIsUntagged() {
        let thought = Thought(body: "Hello", nextDueAt: now)
        thought.tags = nil
        #expect(thought.isUntagged)
    }

    @Test func emptyTagsIsUntagged() {
        let thought = Thought(body: "Hello", nextDueAt: now)
        thought.tags = []
        #expect(thought.isUntagged)
    }

    @Test func taggedIsNotUntagged() throws {
        let container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let thought = Thought(body: "Hello #swift", nextDueAt: now)
        container.mainContext.insert(thought)
        thought.tags = [ThoughtReps.Tag(name: "swift", displayName: "swift")]
        #expect(!thought.isUntagged)
    }
}
