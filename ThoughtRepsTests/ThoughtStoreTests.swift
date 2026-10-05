import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// Store behavior against an in-memory SwiftData container, with a fixed clock.
@MainActor
@Suite("ThoughtStore")
struct ThoughtStoreTests {
    let container: ModelContainer
    let store: ThoughtStore
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, ratingPrompt: .throwaway())
    }

    func days(_ n: Int, from date: Date) -> Date {
        Scheduler.adding(days: n, to: date, calendar: .current)
    }

    func tagNames() throws -> [String] {
        try container.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()).map(\.name).sorted()
    }

    @Test func newThoughtWaitsForItsInterval() {
        let thought = store.create(body: "Hello", now: now)
        #expect(thought.nextDueAt == days(7, from: now))
        #expect(!thought.isDue(now: now))
        #expect(thought.viewCount == 0)
    }

    @Test func viewRequeuesFromNow() {
        let thought = store.create(body: "Hello", now: now)
        let later = days(10, from: now)
        store.markViewed(thought, now: later)
        #expect(thought.viewCount == 1)
        #expect(thought.lastViewedAt == later)
        #expect(thought.nextDueAt == days(7, from: later))
    }

    @Test func snoozeMovesDueWithoutCountingAView() {
        let thought = store.create(body: "Hello", now: now)
        store.snooze(thought, days: 1, now: now)
        #expect(thought.nextDueAt == days(1, from: now))
        #expect(thought.viewCount == 0)
        #expect(thought.lastViewedAt == nil)
    }

    @Test func editingTheIntervalReschedules() {
        let thought = store.create(body: "Hello", now: now)
        store.update(thought, body: "Hello", blocks: [], intervalDays: 1, now: now)
        #expect(thought.nextDueAt == days(1, from: now))
    }

    @Test func editingWithoutIntervalChangeKeepsSchedule() {
        let thought = store.create(body: "Hello", now: now)
        store.snooze(thought, days: 30, now: now)
        store.update(thought, body: "Edited", blocks: [], intervalDays: nil, now: now)
        #expect(thought.nextDueAt == days(30, from: now))
    }

    @Test func editingTheIntervalReanchorsFromLastView() {
        let thought = store.create(body: "Hello", now: now)
        let viewed = days(10, from: now)
        store.markViewed(thought, now: viewed)
        store.update(thought, body: "Hello", blocks: [], intervalDays: 2, now: days(11, from: now))
        #expect(thought.nextDueAt == days(2, from: viewed))
    }

    @Test func setIntervalMatchesEditorPath() {
        let viaMenu = store.create(body: "A", now: now)
        let viaEditor = store.create(body: "B", now: now)
        store.setInterval(viaMenu, days: 3, now: now)
        store.update(viaEditor, body: "B", blocks: [], intervalDays: 3, now: now)
        #expect(viaMenu.nextDueAt == viaEditor.nextDueAt)
    }

    @Test func archiveAndRestore() {
        let thought = store.create(body: "Hello", now: now)
        store.setPinned(thought, true)
        store.archive(thought, now: now)
        #expect(thought.isArchived)
        #expect(!thought.isPinned)
        let later = days(3, from: now)
        store.restore(thought, now: later)
        #expect(!thought.isArchived)
        #expect(thought.archivedAt == nil)
        #expect(thought.isDue(now: later))
    }

    @Test func tagsAreSharedCaseInsensitively() throws {
        let a = store.create(body: "#Swift notes", now: now)
        let b = store.create(body: "more #swift", now: now)
        #expect(try tagNames() == ["swift"])
        #expect(a.tags?.first?.displayName == "Swift")
        #expect(b.tags?.first?.persistentModelID == a.tags?.first?.persistentModelID)
    }

    @Test func tagRemovedFromBodyIsPrunedAtLaunch() throws {
        let thought = store.create(body: "#swift #study", now: now)
        store.update(thought, body: "#swift", blocks: [], intervalDays: nil, now: now)
        #expect(try tagNames() == ["study", "swift"]) // kept until launch
        store.pruneOrphanTags()
        #expect(try tagNames() == ["swift"])
    }

    @Test func pruneKeepsTagsStillInUse() throws {
        let a = store.create(body: "#swift #study", now: now)
        store.create(body: "#swift", now: now)
        store.delete(a)
        store.pruneOrphanTags()
        #expect(try tagNames() == ["swift"])
    }

    @Test func archivedThoughtsKeepTheirTags() throws {
        let thought = store.create(body: "#swift", now: now)
        store.archive(thought, now: now)
        store.pruneOrphanTags()
        #expect(try tagNames() == ["swift"])
    }

    @Test func blocksAreReplacedOnEdit() {
        let thought = store.create(body: "Q", blocks: [BlockDraft(content: "A1")], now: now)
        store.update(thought, body: "Q", blocks: [BlockDraft(content: "A2"), BlockDraft(content: "  ")], intervalDays: nil, now: now)
        #expect(thought.sortedBlocks.map(\.content) == ["A2"])
    }

    @Test func deleteAllEmptiesTheStore() throws {
        store.create(body: "#a", blocks: [BlockDraft(content: "x")], now: now)
        store.create(body: "#b", now: now)
        store.deleteAll()
        let context = container.mainContext
        #expect(try context.fetchCount(FetchDescriptor<Thought>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ThoughtReps.Tag>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 0)
    }
}
