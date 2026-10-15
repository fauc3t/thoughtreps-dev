import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// A remote content change landing on an archived, pinned or Learn thought leaves its state and schedule groups alone.
@MainActor
@Suite("Applying remote content to special thoughts")
struct SyncApplyRemoteStateTests {
    enum Kind: CaseIterable, CustomTestStringConvertible {
        case archived, pinned, learn
        var testDescription: String { "\(self)" }
    }

    struct Groups: Equatable {
        var isArchived: Bool
        var archivedAt: Date?
        var isPinned: Bool
        var stateChangedAt: Date
        var nextDueAt: Date
        var scheduleChangedAt: Date
        var mode: IntervalMode
        var learnIntervalDays: Int?

        init(_ thought: Thought) {
            isArchived = thought.isArchived
            archivedAt = thought.archivedAt
            isPinned = thought.isPinned
            stateChangedAt = thought.stateChangedAt
            nextDueAt = thought.nextDueAt
            scheduleChangedAt = thought.scheduleChangedAt
            mode = thought.intervalMode
            learnIntervalDays = thought.learnIntervalDays
        }
    }

    let container: ModelContainer
    let state = SyncState(location: .inMemory)
    let defaults: UserDefaults
    let index = SearchIndex(location: .inMemory)
    var store: ThoughtStore
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() async throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        let suite = "ApplyRemoteState-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
        store.pendingImageSaves = PendingImageSaves(defaults: defaults)
        store.ratingPrompt = RatingPrompt(defaults: defaults)
        store.searchIndex = index
        store.syncState = state
        store.syncDefaults = defaults
        self.store = store
        try await state.configure(vaultID: "vault")
    }

    var context: ModelContext { container.mainContext }

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func make(_ kind: Kind, body: String) -> Thought {
        let thought = store.create(body: body, intervalDays: nil, now: at(0))
        switch kind {
        case .archived: store.archive(thought, now: at(1))
        case .pinned: store.setPinned(thought, true, now: at(1))
        case .learn: store.setLearnMode(thought, true, now: at(1))
        }
        return thought
    }

    func remote(of content: ThoughtContentRecord, body: String, base: ThoughtContentRecord, baseHash: String? = nil) -> RemoteThought {
        var changed = content
        changed.body = body
        changed.updatedAt = at(100)
        return RemoteThought(id: content.id, content: changed, contentBase: base, contentBaseHash: baseHash ?? SyncPayload.hash(of: plaintext(base)))
    }

    func plaintext(_ content: ThoughtContentRecord) -> Data {
        (try? SyncPayload.thoughtContent(content).encoded()) ?? Data()
    }

    func expectClean() async throws {
        #expect(try IntegrityChecker.check(context).isEmpty)
        #expect(try await SearchIndexChecker.check(context, index: index).isEmpty)
    }

    @Test(arguments: Kind.allCases)
    func aCleanTakeKeepsTheOtherGroupsAndReindexes(kind: Kind) async throws {
        let thought = make(kind, body: "one\ntwo")
        let groups = Groups(thought)
        let base = ThoughtContentRecord(thought)
        let outcome = store.applyRemote(RemoteBatch(thoughts: [remote(of: base, body: "one\ntwo\nthree", base: base)]), now: at(200))
        #expect(outcome.saved && outcome.requeue.isEmpty)
        #expect(thought.body == "one\ntwo\nthree")
        #expect(Groups(thought) == groups)
        try await expectClean()
    }

    @Test(arguments: Kind.allCases)
    func aMergeKeepsTheOtherGroupsAndReindexes(kind: Kind) async throws {
        let thought = make(kind, body: "one\ntwo\nthree\nfour")
        let base = ThoughtContentRecord(thought)
        store.update(thought, body: "ONE\ntwo\nthree\nfour", blocks: [], intervalDays: thought.intervalDays, now: at(50))
        let groups = Groups(thought)
        let outcome = store.applyRemote(RemoteBatch(thoughts: [remote(of: base, body: "one\ntwo\nthree\nFOUR", base: base)]), now: at(200))
        #expect(outcome.saved && outcome.requeue == [.thought(thought.id)])
        #expect(thought.body == "ONE\ntwo\nthree\nFOUR")
        #expect(Groups(thought) == groups)
        #expect(try context.fetchCount(FetchDescriptor<Thought>(predicate: ThoughtCounts.conflictCopies)) == 0)
        try await expectClean()
    }

    @Test(arguments: Kind.allCases)
    func aConflictKeepsTheOtherGroupsAndTheCopyStartsFresh(kind: Kind) async throws {
        let thought = make(kind, body: "one\ntwo")
        let base = ThoughtContentRecord(thought)
        store.update(thought, body: "one\nmine", blocks: [], intervalDays: thought.intervalDays, now: at(50))
        let groups = Groups(thought)
        let outcome = store.applyRemote(RemoteBatch(thoughts: [remote(of: base, body: "one\ntheirs", base: base)]), now: at(200))
        #expect(outcome.saved)
        let copy = try #require(try context.fetch(FetchDescriptor<Thought>(predicate: ThoughtCounts.conflictCopies)).first)
        #expect(copy.conflictOfID == thought.id)
        #expect(!copy.isArchived && !copy.isPinned && copy.intervalMode == .fixed)
        #expect(Set([thought.body, copy.body]) == ["one\ntheirs", "one\nmine"])
        #expect(Groups(thought) == groups)
        #expect(outcome.requeue.contains(.thought(copy.id)))
        try await expectClean()
    }
}
