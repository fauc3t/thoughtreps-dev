import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

extension RatingPrompt {
    /// A prompt backed by an empty, uniquely named suite so tests never touch `.standard`.
    static func throwaway() -> RatingPrompt {
        let name = "RatingPromptTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return RatingPrompt(defaults: defaults)
    }
}

@MainActor
@Suite("RatingPrompt")
struct RatingPromptTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func makePrompt() -> RatingPrompt { .throwaway() }

    @Test func failedSaveDoesNotSetPending() throws {
        let container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let prompt = makePrompt()
        for _ in 0..<9 { prompt.recordDueOpen() }
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
        store.ratingPrompt = prompt
        let thought = Thought(body: "hello", createdAt: now, nextDueAt: now)
        container.mainContext.insert(thought)
        store.save = { _ in throw CocoaError(.fileWriteUnknown) }

        #expect(!store.markViewed(thought, now: now))
        #expect(prompt.dueOpenCount == 9)
        #expect(!prompt.isPending)
    }

    @Test func dueUnpinnedUnarchivedCounts() {
        #expect(Scheduler.countsAsDueOpen(isPinned: false, isArchived: false, nextDueAt: now, now: now))
        #expect(Scheduler.countsAsDueOpen(isPinned: false, isArchived: false, nextDueAt: now.addingTimeInterval(-60), now: now))
    }

    @Test func notDuePinnedOrArchivedDoNotCount() {
        #expect(!Scheduler.countsAsDueOpen(isPinned: false, isArchived: false, nextDueAt: now.addingTimeInterval(1), now: now))
        #expect(!Scheduler.countsAsDueOpen(isPinned: true, isArchived: false, nextDueAt: now, now: now))
        #expect(!Scheduler.countsAsDueOpen(isPinned: false, isArchived: true, nextDueAt: now, now: now))
    }

    @Test func becomesPendingAtTenAndStopsOnceAsked() {
        let prompt = makePrompt()
        for _ in 0..<9 { prompt.recordDueOpen() }
        #expect(!prompt.isPending)
        prompt.recordDueOpen()
        #expect(prompt.isPending)
        prompt.markAsked()
        #expect(!prompt.isPending && prompt.wasAsked)
        prompt.recordDueOpen()
        #expect(!prompt.isPending)
    }

    @Test func storeCountsOnlySuccessfulDueOpens() throws {
        let container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let prompt = makePrompt()
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7)
        store.ratingPrompt = prompt
        let thought = Thought(body: "hello", createdAt: now, nextDueAt: now)
        container.mainContext.insert(thought)

        store.markViewed(thought, now: now)
        #expect(prompt.dueOpenCount == 1)
        store.markViewed(thought, now: now)
        #expect(prompt.dueOpenCount == 1)

        thought.nextDueAt = now
        store.save = { _ in throw CocoaError(.fileWriteUnknown) }
        store.markViewed(thought, now: now)
        #expect(prompt.dueOpenCount == 1)
    }
}
