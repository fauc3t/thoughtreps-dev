import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Applying remote records")
struct SyncApplyRemoteTests {
    let container: ModelContainer
    let state = SyncState(location: .inMemory)
    let defaults: UserDefaults
    let index = SearchIndex(location: .inMemory)
    var store: ThoughtStore
    var failNextSave = Box()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    final class Box {
        var value = false
    }

    init() async throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        let suite = "ApplyRemote-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let failure = failNextSave
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), save: {
            if failure.value {
                failure.value = false
                throw InjectedSaveFailure()
            }
            try $0.save()
        })
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

    /// A thought as another device would have pushed it, from a store of its own.
    func remote(
        body: String = "remote #tagged", updated: Double = 10, schedule: Double = 10, state stateClock: Double = 10, id: UUID = UUID()
    ) throws -> (content: ThoughtContentRecord, meta: ThoughtMetaRecord) {
        let source = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(source) {} }
        let sourceStore = ThoughtStore(
            context: source.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), pendingImageSaves: PendingImageSaves(defaults: defaults),
            ratingPrompt: RatingPrompt(defaults: defaults)
        )
        let thought = sourceStore.create(body: body, now: at(0))
        thought.id = id
        thought.updatedAt = at(updated)
        thought.scheduleChangedAt = at(schedule)
        thought.stateChangedAt = at(stateClock)
        return (ThoughtContentRecord(thought), ThoughtMetaRecord(thought))
    }

    @discardableResult func apply(_ thoughts: [RemoteThought], tags: [TagRecord] = [], settings: SettingsRecord? = nil) -> RemoteOutcome {
        store.applyRemote(RemoteBatch(thoughts: thoughts, tags: tags, settings: settings), now: at(0))
    }

    func queued() async throws -> Set<SyncEntity> {
        await state.flush()
        return Set(try await state.outbox(limit: Int.max).map(\.entity))
    }

    func local(_ id: UUID) throws -> Thought? {
        try context.fetch(FetchDescriptor<Thought>(predicate: #Predicate { $0.id == id })).first
    }

    func expectClean() async throws {
        #expect(try IntegrityChecker.check(context).isEmpty)
        #expect(try await SearchIndexChecker.check(context, index: index).isEmpty)
    }

    @Test func bothRecordsCreateAThoughtWithoutQueueingAnything() async throws {
        let (content, meta) = try remote()
        let outcome = apply([RemoteThought(id: content.id, content: content, meta: meta)])
        #expect(outcome == RemoteOutcome())
        let thought = try #require(try local(content.id))
        #expect(thought.body == "remote #tagged")
        #expect(thought.sortedTags.map(\.name) == ["tagged"])
        #expect(thought.updatedAt == at(10))
        #expect(try await queued().isEmpty)
        try await expectClean()
        #expect(defaults.object(forKey: AppSettings.Key.ratingDueOpenCount) == nil)
    }

    @Test func oneRecordIsHeldBack() async throws {
        let (content, meta) = try remote()
        #expect(apply([RemoteThought(id: content.id, content: content)]).held == [content.id])
        #expect(apply([RemoteThought(id: content.id, meta: meta)]).held == [content.id])
        #expect(try local(content.id) == nil)
        let fromBase = apply([RemoteThought(id: content.id, meta: meta, contentBase: content)])
        #expect(fromBase.held.isEmpty)
        #expect(try local(content.id) != nil)
    }

    @Test func eachMetaGroupFollowsItsOwnClockAndTheLocalWinnerIsQueued() async throws {
        let (content, meta) = try remote(schedule: 10, state: 10)
        apply([RemoteThought(id: content.id, content: content, meta: meta)])
        let thought = try #require(try local(content.id))
        var newer = meta
        newer.scheduleChangedAt = at(5)
        newer.nextDueAt = at(99_999)
        newer.isPinned = true
        newer.stateChangedAt = at(20)
        newer.viewCount = 4
        newer.lastViewedAt = at(15)
        let outcome = apply([RemoteThought(id: content.id, meta: newer)])
        #expect(thought.nextDueAt == meta.nextDueAt, "the local schedule is newer")
        #expect(thought.scheduleChangedAt == at(10))
        #expect(thought.isPinned && thought.stateChangedAt == at(20), "the remote state is newer")
        #expect(thought.viewCount == 4 && thought.lastViewedAt == at(15), "counters take the max")
        #expect(outcome.requeue == [.thought(content.id)], "the local schedule must go back out")
        #expect(try await queued().isEmpty, "applying doesn't queue by itself")
        try await expectClean()
    }

    @Test func equalClocksWithDifferentValuesPickTheSameSideOnEveryDevice() throws {
        let (_, base) = try remote()
        var x = base
        var y = base
        x.nextDueAt = at(1000)
        y.nextDueAt = at(2000)
        let forward = RemoteMerge.metaWins(local: x, remote: y)
        let backward = RemoteMerge.metaWins(local: y, remote: x)
        #expect(forward.schedule != backward.schedule)
        x.isPinned = true
        let state = RemoteMerge.metaWins(local: x, remote: y)
        #expect(state.state != RemoteMerge.metaWins(local: y, remote: x).state)
    }

    @Test func aDeletionNewerThanTheContentDeletesAndOlderOneKeepsTheThought() async throws {
        let (content, meta) = try remote(updated: 50)
        apply([RemoteThought(id: content.id, content: content, meta: meta)])
        let older = apply([RemoteThought(id: content.id, deletion: SyncDeletion(id: content.id, deletedAt: at(40)))])
        #expect(try local(content.id) != nil)
        #expect(older.requeue == [.thought(content.id)])
        let newer = apply([RemoteThought(id: content.id, deletion: SyncDeletion(id: content.id, deletedAt: at(60)))])
        #expect(newer.saved && newer.requeue.isEmpty)
        #expect(try local(content.id) == nil)
        let tombstone = try #require(try context.fetch(FetchDescriptor<Tombstone>()).first)
        #expect(tombstone.id == content.id && tombstone.deletedAt == at(60))
        #expect(try await queued().isEmpty)
        try await expectClean()
    }

    @Test func aTombstoneBlocksOlderRecordsAndYieldsToNewerOnes() async throws {
        let (content, meta) = try remote(updated: 10)
        let thought = store.create(body: "mine", now: at(0))
        let id = thought.id
        store.delete(thought, now: at(100))
        var oldContent = content
        oldContent.id = id
        var oldMeta = meta
        oldMeta.id = id
        let ignored = apply([RemoteThought(id: id, content: oldContent, meta: oldMeta)])
        #expect(try local(id) == nil)
        #expect(ignored.requeue == [.thought(id)], "the deletion has to be pushed against the remote seq")

        oldContent.updatedAt = at(200)
        let revived = apply([RemoteThought(id: id, content: oldContent, meta: oldMeta)])
        #expect(revived.saved)
        #expect(try local(id) != nil)
        #expect(try context.fetch(FetchDescriptor<Tombstone>()).isEmpty)
        try await expectClean()
    }

    @Test func aFailedSaveLeavesAConsistentStoreAndTheRetryFinishesTheJob() async throws {
        let (content, meta) = try remote()
        failNextSave.value = true
        let failed = apply([RemoteThought(id: content.id, content: content, meta: meta)])
        #expect(!failed.saved)
        try await expectClean()
        let retried = apply([RemoteThought(id: content.id, content: content, meta: meta)])
        #expect(retried.saved)
        #expect(try local(content.id) != nil)
        try await expectClean()
    }

    @Test func editingStoredContentGoesThroughTheSameStepsAsAnUpdate() async throws {
        let (content, meta) = try remote(body: "v1 #one")
        apply([RemoteThought(id: content.id, content: content, meta: meta)])
        var edited = content
        edited.body = "v2 #two"
        edited.updatedAt = at(50)
        edited.blocks = [BlockRecord(id: UUID(), kindRaw: BlockKind.markdown.rawValue, title: nil, content: "block #three", order: 0, images: [])]
        let outcome = apply([RemoteThought(id: content.id, content: edited, contentBase: content, contentBaseHash: SyncPayload.hash(of: try SyncPayload.thoughtContent(content).encoded()))])
        #expect(outcome == RemoteOutcome())
        let thought = try #require(try local(content.id))
        #expect(thought.body == "v2 #two" && thought.updatedAt == at(50))
        #expect(thought.sortedTags.map(\.name) == ["three", "two"])
        try await expectClean()
    }

    @Test func aCollisionGoesThroughTheResolver() async throws {
        let (content, meta) = try remote(body: "base", updated: 10)
        apply([RemoteThought(id: content.id, content: content, meta: meta)])
        let thought = try #require(try local(content.id))
        store.update(thought, body: "local edit", blocks: [], intervalDays: nil, now: at(30))
        var remoteEdit = content
        remoteEdit.body = "remote edit"
        remoteEdit.updatedAt = at(20)
        let baseHash = SyncPayload.hash(of: try SyncPayload.thoughtContent(content).encoded())

        let keepLocal = apply([RemoteThought(id: content.id, content: remoteEdit, contentBase: content, contentBaseHash: baseHash)])
        #expect(thought.body == "local edit")
        let remoteCopy = ConflictCopy.copyID(of: content.id, losing: remoteEdit)
        #expect(keepLocal.requeue == [.thought(content.id), .thought(remoteCopy)], "the remote edit lost and became a copy")
        #expect(try local(remoteCopy)?.body == "remote edit")

        remoteEdit.updatedAt = at(40)
        let localCopy = ConflictCopy.copyID(of: content.id, losing: ThoughtContentRecord(thought))
        let takeRemote = apply([RemoteThought(id: content.id, content: remoteEdit, contentBase: content, contentBaseHash: baseHash)])
        #expect(thought.body == "remote edit")
        #expect(takeRemote.requeue == [.thought(localCopy)], "the local edit lost and became a copy")
        #expect(try local(localCopy)?.body == "local edit")
        try await expectClean()
    }

    @Test func aLosingImageWithNoBytesIsLeftOutOfTheCopyInsteadOfStallingSync() async throws {
        let (content, meta) = try remote(body: "base", updated: 10)
        apply([RemoteThought(id: content.id, content: content, meta: meta)])
        let thought = try #require(try local(content.id))
        store.update(thought, body: "local edit", blocks: [], intervalDays: nil, now: at(30))
        let missing = UUID()
        var loser = content
        loser.body = "remote edit\n\(ImageToken.token(for: missing))\nmore"
        loser.updatedAt = at(20)
        loser.images = [ImageRecord(id: missing, width: 4, height: 3, order: 0)]
        loser.blocks = [BlockRecord(id: UUID(), kindRaw: "gallery", title: nil, content: "", order: 0, images: [ImageRecord(id: UUID(), width: 4, height: 3, order: 0)])]
        let baseHash = SyncPayload.hash(of: try SyncPayload.thoughtContent(content).encoded())
        let outcome = apply([RemoteThought(id: content.id, content: loser, contentBase: content, contentBaseHash: baseHash)])
        #expect(outcome.saved)
        let copy = try #require(try local(ConflictCopy.copyID(of: content.id, losing: loser)))
        #expect(copy.body == "remote edit\nmore" && copy.blocks?.isEmpty == true && copy.images?.isEmpty == true)
        try await expectClean()
    }

    @Test func tagsFollowTheLaterColorAndSettingsTheLaterWriter() async throws {
        let (content, meta) = try remote(body: "x #paint")
        apply([RemoteThought(id: content.id, content: content, meta: meta)])
        let tag = try #require(try local(content.id)?.sortedTags.first)
        store.setColor(tag, hex: "#3352D1", now: at(100))
        let older = TagRecord(name: "paint", displayName: "paint", colorHex: "#FF0000", updatedAt: at(50))
        let kept = apply([], tags: [older])
        #expect(tag.colorHex == "#3352D1")
        #expect(kept.requeue == [.tag("paint")])
        let newer = TagRecord(name: "paint", displayName: "Paint", colorHex: "#00FF00", updatedAt: at(150))
        #expect(apply([], tags: [newer]).requeue.isEmpty)
        #expect(tag.colorHex == "#00FF00" && tag.displayName == "Paint" && tag.updatedAt == at(150))

        defaults.set(5, forKey: AppSettings.Key.defaultIntervalDays)
        defaults.set(at(10), forKey: AppSettings.Key.defaultIntervalChangedAt)
        #expect(apply([], settings: SettingsRecord(defaultIntervalDays: 9, changedAt: at(5))).requeue == [.settings])
        #expect(AppSettings.defaultIntervalDays(in: defaults) == 5)
        #expect(apply([], settings: SettingsRecord(defaultIntervalDays: 9, changedAt: at(20))).requeue.isEmpty)
        #expect(AppSettings.defaultIntervalDays(in: defaults) == 9)
        #expect(AppSettings.defaultIntervalChangedAt(in: defaults) == at(20))
    }

    @Test func aRecordWhoseImagesBelongToAnotherThoughtIsSkipped() async throws {
        let image = newImage(3)
        let owner = store.create(body: "owner " + ImageToken.token(for: image.id), images: [image], now: at(0))
        let (content, meta) = try remote(body: "thief " + ImageToken.token(for: image.id))
        var stolen = content
        stolen.images = [ImageRecord(id: image.id, width: 40, height: 30, order: 0)]
        let outcome = apply([RemoteThought(id: stolen.id, content: stolen, meta: meta, images: [image.id: fakeImage(3)])])
        #expect(outcome.rejected == [stolen.id])
        #expect(try local(stolen.id) == nil)
        #expect(owner.images?.count == 1)
        try await expectClean()
    }

    @Test func remoteClocksRaiseTheSkewClock() async throws {
        let (content, meta) = try remote(updated: 5_000, schedule: 6_000, state: 7_000)
        apply([RemoteThought(id: content.id, content: content, meta: meta)])
        #expect(SyncClock(defaults: defaults).highestSeen == at(7_000))
        let thought = store.create(body: "after", now: at(1))
        #expect(thought.updatedAt == at(7_000).addingTimeInterval(0.001))
    }
}
