import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// The editor's save over a thought that changed while it was open (remote edit, remote delete), and the
/// settings and conflict-copy guards that go with it.
@MainActor
@Suite("Editor save against concurrent changes")
struct EditSaveTests {
    let container: ModelContainer
    let state = SyncState(location: .inMemory)
    let defaults: UserDefaults
    let index = SearchIndex(location: .inMemory)
    var store: ThoughtStore
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() async throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        let suite = "EditSave-\(UUID().uuidString)"
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

    func make(_ body: String, blocks: [BlockDraft] = [], images: [ImageDraft] = []) async throws -> Thought {
        let thought = store.create(body: body, blocks: blocks, images: images, intervalDays: nil, now: at(0))
        try await markEverythingSynced(context: context, state: state, defaults: defaults)
        return thought
    }

    func copies() throws -> [Thought] {
        try context.fetch(FetchDescriptor<Thought>(predicate: ThoughtCounts.conflictCopies))
    }

    func queued() async throws -> Set<SyncEntity> {
        await state.flush()
        return Set(try await state.outbox(limit: Int.max).map(\.entity))
    }

    func expectClean() async throws {
        #expect(try IntegrityChecker.check(context).isEmpty)
        #expect(try await SearchIndexChecker.check(context, index: index).isEmpty)
    }

    /// Another device's change landing while the editor is open.
    func remoteEdit(_ thought: Thought, body: String, blocks: [BlockDraft]? = nil, at seconds: Double = 10) {
        store.update(
            thought, body: body, blocks: blocks ?? RandomizedOperationTests.currentDrafts(of: thought), intervalDays: thought.intervalDays, now: at(seconds)
        )
    }

    // MARK: Saving over a remote edit

    @Test func anUntouchedStoredThoughtIsAPlainUpdate() async throws {
        let thought = try await make("one\ntwo")
        let base = EditBase(thought)
        #expect(store.saveEdit(base, body: "one\ntwo\nthree", blocks: [], intervalDays: nil, learn: false, now: at(20)))
        #expect(thought.body == "one\ntwo\nthree")
        #expect(try copies().isEmpty)
        #expect(try await queued().contains(.thought(thought.id)))
        try await expectClean()
    }

    @Test func aRemoteEditOnOtherLinesIsMergedNotErased() async throws {
        let thought = try await make("one\ntwo\nthree\nfour\nfive")
        let base = EditBase(thought)
        remoteEdit(thought, body: "one\ntwo\nthree\nfour\nFIVE")
        try await markEverythingSynced(context: context, state: state, defaults: defaults)
        #expect(store.saveEdit(base, body: "ONE\ntwo\nthree\nfour\nfive", blocks: [], intervalDays: nil, learn: false, now: at(20)))
        #expect(thought.body == "ONE\ntwo\nthree\nfour\nFIVE")
        #expect(try copies().isEmpty)
        #expect(thought.updatedAt >= at(20))
        #expect(try await queued().contains(.thought(thought.id)))
        try await expectClean()
    }

    @Test func overlappingEditsSaveTheDraftAndKeepTheStoredVersionAsACopy() async throws {
        let thought = try await make("one\ntwo\nthree")
        let base = EditBase(thought)
        remoteEdit(thought, body: "one\nREMOTE\nthree")
        let stored = ThoughtContentRecord(thought)
        try await markEverythingSynced(context: context, state: state, defaults: defaults)
        #expect(store.saveEdit(base, body: "one\nMINE\nthree", blocks: [], intervalDays: nil, learn: false, now: at(20)))
        #expect(thought.body == "one\nMINE\nthree")
        let copy = try #require(try copies().first)
        #expect(try copies().count == 1)
        #expect(copy.body == "one\nREMOTE\nthree")
        #expect(copy.conflictOfID == thought.id)
        #expect(copy.id == ConflictCopy.copyID(of: thought.id, losing: stored))
        #expect(copy.nextDueAt == at(20))
        #expect(try await queued().isSuperset(of: [.thought(thought.id), .thought(copy.id)]))
        try await expectClean()
    }

    @Test func retryingAfterTheEditFailedAfterTheCopyWasSavedDoesNotMakeASecondCopy() async throws {
        let thought = try await make("one\ntwo\nthree")
        let base = EditBase(thought)
        remoteEdit(thought, body: "one\nREMOTE\nthree")
        var failing = store
        var saves = 0
        failing.save = { context in
            saves += 1
            if saves == 2 { throw InjectedSaveFailure() }
            try context.save()
        }
        #expect(!failing.saveEdit(base, body: "one\nMINE\nthree", blocks: [], intervalDays: nil, learn: false, now: at(20)))
        #expect(thought.body == "one\nREMOTE\nthree", "the draft wasn't saved")
        #expect(try copies().count == 1, "the copy was")
        #expect(store.saveEdit(base, body: "one\nMINE\nthree", blocks: [], intervalDays: nil, learn: false, now: at(30)))
        #expect(thought.body == "one\nMINE\nthree")
        #expect(try copies().count == 1, "the same stored content gives the same copy")
        try await expectClean()
    }

    @Test func blocksAreMergedToo() async throws {
        let thought = try await make("title", blocks: [BlockDraft(content: "alpha")])
        let base = EditBase(thought)
        let opened = RandomizedOperationTests.currentDrafts(of: thought)
        remoteEdit(thought, body: "title", blocks: opened + [BlockDraft(content: "remote block")])
        #expect(store.saveEdit(base, body: "title edited", blocks: opened, intervalDays: nil, learn: false, now: at(20)))
        #expect(thought.body == "title edited")
        #expect(thought.sortedBlocks.map(\.content) == ["alpha", "remote block"])
        #expect(try copies().isEmpty)
        try await expectClean()
    }

    @Test func aRemoteImageSurvivesAMergeAndTheEditorsNewImageIsAdded() async throws {
        let thought = try await make("start\nmiddle\nend")
        let base = EditBase(thought)
        let remoteImage = ImageDraft(id: UUID(), processed: fakeImage(1))
        store.update(
            thought, body: "start\nmiddle\nend\n\(ImageToken.token(for: remoteImage.id))", blocks: [], images: [remoteImage],
            intervalDays: nil, now: at(11)
        )
        let mine = ImageDraft(id: UUID(), processed: fakeImage(2))
        let body = "\(ImageToken.token(for: mine.id))\nstart\nmiddle\nend"
        #expect(store.saveEdit(base, body: body, blocks: [], images: [mine], intervalDays: nil, learn: false, now: at(20)))
        #expect(Set((thought.images ?? []).map(\.id)) == [remoteImage.id, mine.id])
        #expect(try copies().isEmpty)
        try await expectClean()
    }

    @Test func aTokenForAnImageTheOtherDeviceRemovedIsNotSavedDangling() async throws {
        let image = ImageDraft(id: UUID(), processed: fakeImage(3))
        let thought = try await make("a\n\(ImageToken.token(for: image.id))\nb", images: [image])
        let base = EditBase(thought)
        remoteEdit(thought, body: "a\nb")
        #expect((thought.images ?? []).isEmpty)
        #expect(store.saveEdit(base, body: "A\n\(ImageToken.token(for: image.id))\nb", blocks: [], intervalDays: nil, learn: false, now: at(20)))
        #expect(!thought.body.contains("img:"))
        try await expectClean()
    }

    @Test func theIntervalIsOnlyWrittenWhenTheEditorChangedIt() async throws {
        let thought = try await make("text")
        let base = EditBase(thought)
        store.setInterval(thought, days: 30, now: at(10))
        #expect(store.saveEdit(base, body: "text!", blocks: [], intervalDays: nil, learn: false, now: at(20)))
        #expect(thought.intervalDays == 30, "the editor didn't touch it")
        #expect(store.saveEdit(EditBase(thought), body: "text!", blocks: [], intervalDays: 3, learn: false, now: at(30)))
        #expect(thought.intervalDays == 3)
    }

    @Test func learnModeFollowsTheEditorOnlyWhenChanged() async throws {
        let thought = try await make("text")
        let base = EditBase(thought)
        store.setLearnMode(thought, true, now: at(10))
        #expect(store.saveEdit(base, body: "text!", blocks: [], intervalDays: nil, learn: false, now: at(20)))
        #expect(thought.intervalMode == .learn, "the other device's change stays")
        #expect(store.saveEdit(EditBase(thought), body: "text!", blocks: [], intervalDays: nil, learn: false, now: at(30)))
        #expect(thought.intervalMode == .fixed, "the editor turned it off")
    }

    // MARK: Deleted while open

    @Test func aThoughtDeletedWhileOpenIsSavedAsANewThought() async throws {
        let thought = try await make("keep this text #tagged")
        let base = EditBase(thought)
        let oldID = thought.id
        store.delete(thought, now: at(10))
        #expect(store.saveEdit(base, body: "keep this text #tagged\nand more", blocks: [BlockDraft(content: "block")], intervalDays: 3, learn: false, now: at(20)))
        let all = try context.fetch(FetchDescriptor<Thought>())
        let saved = try #require(all.first)
        #expect(all.count == 1)
        #expect(saved.id != oldID)
        #expect(saved.body == "keep this text #tagged\nand more")
        #expect(saved.sortedBlocks.map(\.content) == ["block"])
        #expect(saved.intervalDays == 3)
        #expect(saved.sortedTags.map(\.name) == ["tagged"])
        #expect(try await queued().contains(.thought(saved.id)))
        try await expectClean()
    }

    @Test func aDeletedThoughtsNewVersionKeepsOnlyImagesWithBytes() async throws {
        let old = ImageDraft(id: UUID(), processed: fakeImage(4))
        let thought = try await make("x\n\(ImageToken.token(for: old.id))", images: [old])
        let base = EditBase(thought)
        store.delete(thought, now: at(10))
        let fresh = ImageDraft(id: UUID(), processed: fakeImage(5))
        let body = "x\n\(ImageToken.token(for: old.id))\n\(ImageToken.token(for: fresh.id))"
        #expect(store.saveEdit(base, body: body, blocks: [], images: [ImageDraft(id: old.id), fresh], intervalDays: nil, learn: true, now: at(20)))
        let saved = try #require(try context.fetch(FetchDescriptor<Thought>()).first)
        #expect(saved.body == "x\n\n\(ImageToken.token(for: fresh.id))")
        #expect(saved.intervalMode == .learn)
        try await expectClean()
    }

    // MARK: Conflict copy resolution

    @Test func keepOriginalRefusesAThoughtThatIsNotACopy() async throws {
        let thought = try await make("plain")
        #expect(!store.keepOriginal(thought, now: at(10)))
        #expect(try context.fetchCount(FetchDescriptor<Thought>()) == 1)
        thought.conflictOfID = UUID()
        #expect(store.keepOriginal(thought, now: at(20)))
        #expect(try context.fetchCount(FetchDescriptor<Thought>()) == 0)
    }

    // MARK: Settings

    @Test func onlyTheUsersOwnChangeStampsAndQueuesTheSetting() async throws {
        defaults.set(14, forKey: AppSettings.Key.defaultIntervalDays)
        await state.flush()
        #expect(try await state.outbox(limit: Int.max).filter { $0.entity == .settings }.isEmpty, "an external write to the key stamps nothing")
        #expect(AppSettings.defaultIntervalChangedAt(in: defaults) == .distantPast)
        AppSettings.setDefaultIntervalByUser(14, now: at(5), defaults: defaults, sync: state)
        await state.flush()
        #expect(try await state.outbox(limit: Int.max).filter { $0.entity == .settings }.isEmpty, "no change, no stamp")
        AppSettings.setDefaultIntervalByUser(21, now: at(6), defaults: defaults, sync: state)
        await state.flush()
        #expect(AppSettings.defaultIntervalDays(in: defaults) == 21)
        #expect(AppSettings.defaultIntervalChangedAt(in: defaults) >= at(6))
        #expect(try await state.outbox(limit: Int.max).contains { $0.entity == .settings })
    }

    @Test func theEditSheetKeepsTheThoughtItFirstFound() {
        #expect(EditThoughtSheet.resolve(held: "kept", found: nil) == "kept")
        #expect(EditThoughtSheet.resolve(held: nil, found: "found") == "found")
        #expect(EditThoughtSheet.resolve(held: String?.none, found: String?.none) == nil)
    }

    @Test func aRemoteSettingsApplyDoesNotRestampOrQueueTheSetting() async throws {
        let remote = SettingsRecord(defaultIntervalDays: 14, changedAt: at(500))
        let outcome = store.applyRemote(RemoteBatch(settings: remote), now: at(600))
        #expect(outcome.requeue.isEmpty)
        #expect(AppSettings.defaultIntervalDays(in: defaults) == 14)
        #expect(AppSettings.defaultIntervalChangedAt(in: defaults) == at(500))
        await state.flush()
        #expect(try await state.outbox(limit: Int.max).filter { $0.entity == .settings }.isEmpty)
    }
}
