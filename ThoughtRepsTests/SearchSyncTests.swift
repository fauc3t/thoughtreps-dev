import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// `ThoughtStore` against an in-memory container and an in-memory search index.
@MainActor
@Suite("Search index sync")
struct SearchSyncTests {
    let container: ModelContainer
    let index = SearchIndex(location: .inMemory)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let failure = FailureSwitch()
    let store: ThoughtStore

    final class FailureSwitch {
        var failSaves = false
    }

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        let failure = failure
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), save: {
            if failure.failSaves { throw InjectedSaveFailure() }
            try $0.save()
        })
        store.searchIndex = index
        self.store = store
    }

    var context: ModelContext { container.mainContext }

    func ids(_ query: String, _ scope: SearchScope = .all) async throws -> [UUID] {
        try await index.search(query, scope: scope).map(\.id)
    }

    func expectInStep(_ comment: Comment? = nil) async throws {
        let violations = try await SearchIndexChecker.check(context, index: index)
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test func createIndexesBodyBlocksAndTags() async throws {
        let thought = store.create(
            body: "# Garden plan\nPlant #tomatoes", blocks: [
                BlockDraft(content: "secret code 1234"),
                BlockDraft(kind: .gallery, title: "Seedlings", images: [newImage()]),
            ], now: now
        )
        #expect(try await ids("garden") == [thought.id])
        #expect(try await ids("secret") == [thought.id])
        #expect(try await ids("seedlings") == [thought.id])
        #expect(try await ids("tomatoes") == [thought.id])
        try await expectInStep()
    }

    @Test func imageTokensAreNotSearchable() async throws {
        let image = newImage()
        let thought = store.create(body: "photo \(ImageToken.token(for: image.id))", images: [image], now: now)
        #expect(try await ids("photo") == [thought.id])
        #expect(try await ids("img").isEmpty)
    }

    @Test func updateReplacesTheIndexedText() async throws {
        let thought = store.create(body: "old words #old", blocks: [BlockDraft(content: "old block")], now: now)
        store.update(thought, body: "new words #fresh", blocks: [BlockDraft(content: "new block")], intervalDays: nil, now: now.addingTimeInterval(60))
        #expect(try await ids("old").isEmpty)
        #expect(try await ids("fresh") == [thought.id])
        #expect(try await ids("block") == [thought.id])
        try await expectInStep()
    }

    @Test func archiveAndRestoreMoveBetweenScopes() async throws {
        let thought = store.create(body: "moving thought", now: now)
        #expect(try await ids("moving", .active) == [thought.id])
        store.archive(thought, now: now)
        #expect(try await ids("moving", .active).isEmpty)
        #expect(try await ids("moving", .archived) == [thought.id])
        store.restore(thought, now: now)
        #expect(try await ids("moving", .active) == [thought.id])
        try await expectInStep()
    }

    @Test func pinnedAndWaitingThoughtsAreActive() async throws {
        let thought = store.create(body: "pinned one", now: now)
        store.setPinned(thought, true)
        #expect(try await ids("pinned", .active) == [thought.id])
        try await expectInStep()
    }

    @Test func deleteRemovesTheRow() async throws {
        let keep = store.create(body: "shared text keep", now: now)
        let gone = store.create(body: "shared text gone", now: now)
        store.delete(gone)
        #expect(try await ids("shared") == [keep.id])
        try await expectInStep()
    }

    @Test func deleteAllEmptiesTheIndex() async throws {
        store.create(body: "one", now: now)
        store.create(body: "two", now: now)
        store.deleteAll()
        #expect(await index.count == 0)
        try await expectInStep()
    }

    @Test func failedCreateIndexesNothing() async throws {
        failure.failSaves = true
        store.create(body: "never saved", now: now)
        failure.failSaves = false
        #expect(await index.count == 0)
        try await expectInStep()
    }

    @Test func failedUpdateKeepsTheIndexAsTheStoreIs() async throws {
        let thought = store.create(body: "original text", now: now)
        failure.failSaves = true
        #expect(!store.update(thought, body: "edited text", blocks: [], intervalDays: nil, now: now.addingTimeInterval(60)))
        failure.failSaves = false
        #expect(thought.body == "original text")
        #expect(try await ids("original") == [thought.id])
        #expect(try await ids("edited").isEmpty)
        try await expectInStep()
    }

    @Test func failedArchiveAndDeleteKeepTheIndexAsTheStoreIs() async throws {
        let thought = store.create(body: "stays active", now: now)
        failure.failSaves = true
        #expect(!store.archive(thought, now: now))
        #expect(!store.delete(thought))
        failure.failSaves = false
        #expect(try await ids("stays", .active) == [thought.id])
        try await expectInStep()
    }

    @Test func importAddsAndReplaces() async throws {
        var rng = SeededGenerator(seed: 7)
        let added = RandomizedOperationTests.randomImported(replacing: nil, now: now, &rng)
        var tally = ImportTally()
        #expect(store.importThoughts([added], tags: [], tally: &tally))
        #expect(await index.document(for: added.record.id) != nil)
        try await expectInStep()

        let existing = try #require(try context.fetch(FetchDescriptor<Thought>()).first)
        let generated = RandomizedOperationTests.randomImported(replacing: existing, now: now, &rng)
        var record = generated.record
        record.updatedAt = existing.updatedAt.addingTimeInterval(500)
        record.body = "replaced via import"
        record.images = []
        store.importThoughts([ImportedThought(record: record, images: generated.images)], tags: [], tally: &tally)
        #expect(try await ids("replaced") == [existing.id])
        try await expectInStep()
    }
}

@MainActor
@Suite("Search index reconciliation")
struct SearchReconciliationTests {
    let container: ModelContainer
    let live = SearchIndex(location: .inMemory)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let store: ThoughtStore

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
        store.searchIndex = live
        self.store = store
    }

    var context: ModelContext { container.mainContext }

    func reconcile(_ index: SearchIndex) async {
        let status = SearchIndexStatus()
        await status.reconcile(container: container, index: index)
        #expect(status.isReconciled)
        #expect(!status.isIndexing)
    }

    func expectInStep(_ index: SearchIndex) async throws {
        let violations = try await SearchIndexChecker.check(context, index: index)
        #expect(violations.isEmpty, "\(violations)")
    }

    @Test func emptyIndexIsFilledFromTheStore() async throws {
        let first = store.create(body: "alpha #one", blocks: [BlockDraft(content: "hidden")], now: now)
        let second = store.create(body: "beta", now: now)
        store.archive(second, now: now)
        let fresh = SearchIndex(location: .inMemory)
        await reconcile(fresh)
        try await expectInStep(fresh)
        #expect(try await fresh.search("hidden").map(\.id) == [first.id])
        #expect(try await fresh.search("beta", scope: .archived).map(\.id) == [second.id])
    }

    @Test func staleMissingAndExtraRowsAreFixed() async throws {
        let stale = store.create(body: "current text", now: now)
        let missing = store.create(body: "missing row", now: now)
        let archived = store.create(body: "archive drift", now: now)
        store.archive(archived, now: now)
        let ghost = UUID()

        await live.upsert([
            searchDocument("outdated text", id: stale.id, updatedAt: now.addingTimeInterval(-5)),
            searchDocument("archive drift", id: archived.id, archived: false, updatedAt: archived.updatedAt),
            searchDocument("ghost", id: ghost),
        ])
        await live.remove(ids: [missing.id])

        await reconcile(live)
        try await expectInStep(live)
        #expect(try await live.search("current").map(\.id) == [stale.id])
        #expect(try await live.search("ghost", scope: .all).isEmpty)
        #expect(try await live.search("missing").map(\.id) == [missing.id])
        #expect(try await live.search("drift", scope: .archived).map(\.id) == [archived.id])
    }

    @Test func matchingRowsAreLeftAlone() async throws {
        store.create(body: "untouched", now: now)
        let summary = try await SearchReconciler(modelContainer: container).reconcile(index: live) {}
        #expect(summary.added == 0 && summary.updated == 0 && summary.removed == 0)
    }

    @Test func manyThoughtsAcrossPages() async throws {
        for n in 0..<2500 {
            context.insert(Thought(body: "bulk \(n)", createdAt: now, nextDueAt: now))
        }
        try context.save()
        let fresh = SearchIndex(location: .inMemory)
        let summary = try await SearchReconciler(modelContainer: container).reconcile(index: fresh) {}
        #expect(summary.added == 2500)
        #expect(await fresh.count == 2500)
        try await expectInStep(fresh)
    }

    @Test func deletedThoughtsAreDroppedOnlyIfReallyGone() async throws {
        let kept = store.create(body: "kept", now: now)
        let gone = store.create(body: "gone", now: now)
        context.delete(gone)
        try context.save()
        await reconcile(live)
        #expect(await live.entries().keys.contains(kept.id))
        #expect(await live.entries().count == 1)
    }

    @Test func scanRunsOffTheMainThread() async throws {
        store.create(body: "one", now: now)
        let fresh = SearchIndex(location: .inMemory)
        let summary = try await Task.detached { [container] in
            try await SearchReconciler(modelContainer: container).reconcile(index: fresh) {}
        }.value
        #expect(summary.added == 1)
        #expect(!summary.ranOnMainThread)
    }

    @Test func conditionalWritesLoseToNewerRows() async throws {
        let id = UUID()
        let seen = SearchIndexEntry(updatedAt: now, isArchived: false)
        await live.upsert([searchDocument("newer edit", id: id, updatedAt: now.addingTimeInterval(10))])
        await live.upsert([(searchDocument("older snapshot", id: id, updatedAt: now), expected: seen)])
        #expect(await live.document(for: id)?.body == "newer edit")
        #expect(await live.remove([(id, seen)]) == 0)
        #expect(await live.count == 1)
        let current = SearchIndexEntry(updatedAt: now.addingTimeInterval(10), isArchived: false)
        #expect(await live.remove([(id, current)]) == 1)
    }

    @Test func sharedIndexIsInMemoryUnderTests() async {
        guard case .inMemory = SearchIndex.shared.location else {
            Issue.record("shared index must not use the real file under tests")
            return
        }
    }
}
