import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// Marks every thought, tag, tombstone and the settings as synced (records written, outbox emptied),
/// as a confirmed push of everything would.
@MainActor
func markEverythingSynced(context: ModelContext, state: SyncState, defaults: UserDefaults) async throws {
    let keys = try SyncKeys(vaultKey: Data(repeating: 7, count: 32))
    var payloads: [SyncPayload] = []
    for thought in try context.fetch(FetchDescriptor<Thought>()) {
        payloads.append(.thoughtContent(ThoughtContentRecord(thought)))
        payloads.append(.thoughtMeta(ThoughtMetaRecord(thought)))
    }
    for tag in try context.fetch(FetchDescriptor<ThoughtReps.Tag>()) {
        payloads.append(.tag(TagRecord(name: tag.name, displayName: tag.displayName, colorHex: tag.colorHex, updatedAt: tag.updatedAt)))
    }
    for tombstone in try context.fetch(FetchDescriptor<Tombstone>()) {
        let deletion = SyncDeletion(id: tombstone.id, deletedAt: tombstone.deletedAt)
        payloads.append(.deletion(.thoughtContent, deletion))
        payloads.append(.deletion(.thoughtMeta, deletion))
    }
    payloads.append(.settings(SettingsRecord.current(defaults: defaults)))
    let records = try payloads.map { payload in
        let plain = try payload.encoded()
        let received = try SyncPayload.decode(plain)
        return SyncedRecord(
            recordKey: keys.recordKey(type: payload.type, entityID: payload.entityID), type: payload.type, entityID: payload.entityID,
            seq: 1, fingerprint: received.fingerprint, baseHash: SyncPayload.hash(of: plain), baseContent: plain
        )
    }
    try await state.markSynced(records, dequeuing: try await state.outbox(limit: Int.max))
}

@MainActor
func throwawayDefaults() -> UserDefaults {
    let name = "SyncTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
@Suite("Sync outbox hooks")
struct SyncOutboxHookTests {
    let container: ModelContainer
    let state = SyncState(location: .inMemory)
    let defaults = throwawayDefaults()
    var store: ThoughtStore
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    init() async throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        var store = ThoughtStore(
            context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: IsolatedDefaults().pendingImageSaves, ratingPrompt: .throwaway()
        )
        store.searchIndex = SearchIndex(location: .inMemory)
        store.syncState = state
        self.store = store
        try await state.configure(vaultID: "vault")
    }

    var context: ModelContext { container.mainContext }

    func queued() async throws -> Set<SyncEntity> {
        Set(try await state.outbox(limit: Int.max).map(\.entity))
    }

    func settle() async throws {
        try await markEverythingSynced(context: context, state: state, defaults: defaults)
    }

    /// Runs `write` against a settled store and returns what it queued.
    func queuedBy(_ write: () -> Void) async throws -> Set<SyncEntity> {
        try await settle()
        write()
        return try await queued()
    }

    @Test func createQueuesTheThoughtAndItsTags() async throws {
        var created: Thought?
        let queued = try await queuedBy { created = store.create(body: "hello #swift #work", now: now) }
        #expect(queued == [.thought(created!.id), .tag("swift"), .tag("work")])
    }

    @Test(arguments: ["update", "addLink", "removeLink"])
    func contentWritersQueueTheThought(writer: String) async throws {
        let thought = store.create(body: "one #a", now: now)
        let other = store.create(body: "two", now: now)
        if writer == "removeLink" { store.addLink(to: other.id, in: thought, now: now) }
        let queued = try await queuedBy {
            switch writer {
            case "update": store.update(thought, body: "changed #b", blocks: [], intervalDays: nil, now: now.addingTimeInterval(1))
            case "addLink": store.addLink(to: other.id, in: thought, now: now.addingTimeInterval(1))
            default: store.removeLink(to: other.id, in: thought, now: now.addingTimeInterval(1))
            }
        }
        #expect(queued.contains(.thought(thought.id)))
        if writer == "update" { #expect(queued.contains(.tag("b"))) }
        #expect(!queued.contains(.thought(other.id)))
    }

    @Test func scheduleStateAndCounterWritersQueueTheThought() async throws {
        let thought = store.create(body: "one", now: now)
        let learner = store.create(body: "learn", learn: true, now: now)
        let later = now.addingTimeInterval(86_400 * 30)
        let writers: [(String, () -> Void)] = [
            ("markViewed", { store.markViewed(thought, now: later) }),
            ("recordVisit", { store.recordVisit(thought, now: later) }),
            ("snooze", { store.snooze(thought, days: 3, now: later) }),
            ("setInterval", { store.setInterval(thought, days: 2, now: later) }),
            ("setLearnMode", { store.setLearnMode(thought, true, now: later) }),
            ("review", { store.review(learner, gotIt: true, now: later) }),
            ("setPinned", { store.setPinned(thought, true, now: later) }),
            ("archive", { store.archive(thought, now: later) }),
            ("restore", { store.restore(thought, now: later) }),
            ("overrideSchedule", { store.overrideSchedule(thought, nextDueAt: later, lastViewedAt: later, viewCount: 4, now: later) }),
        ]
        for (name, write) in writers {
            let target = name == "review" ? learner : thought
            let queued = try await queuedBy(write)
            #expect(queued == [.thought(target.id)], "\(name)")
        }
    }

    @Test func deleteQueuesTheThought() async throws {
        let thought = store.create(body: "doomed", now: now)
        let id = thought.id
        let queued = try await queuedBy { store.delete(thought, now: now.addingTimeInterval(5)) }
        #expect(queued == [.thought(id)])
    }

    @Test func setColorQueuesTheTag() async throws {
        store.create(body: "#swift", now: now)
        let tag = try #require(try context.fetch(FetchDescriptor<ThoughtReps.Tag>()).first)
        let queued = try await queuedBy { store.setColor(tag, hex: "#3352D1", now: now.addingTimeInterval(5)) }
        #expect(queued == [.tag("swift")])
        let unchanged = try await queuedBy { store.setColor(tag, hex: "#3352D1", now: now.addingTimeInterval(9)) }
        #expect(unchanged.isEmpty)
    }

    @Test func importQueuesThoughtsAndRecoloredTags() async throws {
        let existing = store.create(body: "stored #swift", now: now)
        let incoming = ThoughtRecord(
            id: existing.id, body: "from file #swift", createdAt: existing.createdAt, updatedAt: now.addingTimeInterval(100),
            nextDueAt: now, lastViewedAt: nil, viewCount: 0, intervalDays: nil, intervalModeRaw: IntervalMode.fixed.rawValue,
            isPinned: false, isArchived: false, archivedAt: nil, tags: [], blocks: [], images: []
        )
        let fresh = ThoughtRecord(
            id: UUID(), body: "new", createdAt: now, updatedAt: now, nextDueAt: now, lastViewedAt: nil, viewCount: 0,
            intervalDays: nil, intervalModeRaw: IntervalMode.fixed.rawValue, isPinned: false, isArchived: false,
            archivedAt: nil, tags: [], blocks: [], images: []
        )
        let info = [TagRecord(name: "swift", displayName: "Swift", colorHex: "#3352D1", updatedAt: now.addingTimeInterval(50))]
        let queued = try await queuedBy {
            var tally = ImportTally()
            store.importThoughts(
                [ImportedThought(record: incoming, images: [:], files: [:]), ImportedThought(record: fresh, images: [:], files: [:])],
                tags: info, tally: &tally
            )
        }
        #expect(queued == [.thought(existing.id), .thought(fresh.id), .tag("swift")])
    }

    @Test func legacyBlockMigrationQueuesTheOwner() async throws {
        let thought = store.create(body: "one", blocks: [BlockDraft(content: "blocky")], now: now)
        let block = try #require(thought.blocks?.first)
        block.kindRaw = BlockKind.legacyBlurredRaw
        try context.save()
        let queued = try await queuedBy { store.migrateLegacyBlurredBlocks() }
        #expect(queued == [.thought(thought.id)])
    }

    @Test func tokenlessImageCleanupQueuesTheThought() async throws {
        let image = newImage(1)
        let thought = store.create(body: "pic \(ImageToken.token(for: image.id))", images: [image], now: now)
        thought.body = "no token"
        try context.save()
        store.pendingImageSaves.insert(thought.id)
        let queued = try await queuedBy { store.cleanUpPendingImageSaves() }
        #expect(queued == [.thought(thought.id)])
    }

    @Test func deleteAllLeavesSync() async throws {
        store.create(body: "one #a", now: now)
        await state.flush()
        #expect(try await state.outboxCount() > 0)
        store.deleteAll()
        #expect(!state.isEnabled)
        store.create(body: "after", now: now)
        await state.flush()
        await #expect(throws: SyncState.Failure.notConfigured) { try await state.outboxCount() }
    }

    @Test func settingsChangeStampsTheTimeAndQueuesTheRecord() async throws {
        try await settle()
        #expect(AppSettings.defaultIntervalChangedAt(in: defaults) == .distantPast)
        AppSettings.recordDefaultIntervalChange(now: now, defaults: defaults, sync: state)
        #expect(AppSettings.defaultIntervalChangedAt(in: defaults) == now)
        #expect(try await queued() == [.settings])
    }

    @Test func writesWhileSyncIsOffQueueNothingAndTouchNoFile() async throws {
        let url = temporarySyncFile()
        let off = SyncState(location: .file(url))
        var store = store
        store.syncState = off
        let thought = store.create(body: "quiet #tag", now: now)
        store.markViewed(thought, now: now.addingTimeInterval(1))
        await off.flush()
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
}

@MainActor
@Suite("Sync reconciler")
struct SyncReconcilerTests {
    let container: ModelContainer
    let state = SyncState(location: .inMemory)
    let defaults = throwawayDefaults()
    var store: ThoughtStore
    let now = Date(timeIntervalSince1970: 1_790_000_000.123_456_7)

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        var store = ThoughtStore(
            context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: IsolatedDefaults().pendingImageSaves, ratingPrompt: .throwaway()
        )
        store.searchIndex = SearchIndex(location: .inMemory)
        // Writers don't queue here, so only the reconciler can.
        store.syncState = SyncState(location: .inMemory)
        self.store = store
    }

    var context: ModelContext { container.mainContext }

    func reconcile() async throws -> SyncReconciler.Summary {
        let (container, state, settings) = (container, state, SettingsRecord.current(defaults: defaults))
        return try await Task.detached {
            try await SyncReconciler(modelContainer: container).reconcile(state: state, settings: settings)
        }.value
    }

    func queued() async throws -> Set<SyncEntity> {
        Set(try await state.outbox(limit: Int.max).map(\.entity))
    }

    @Test func doesNothingWhileSyncIsOff() async throws {
        store.create(body: "one", now: now)
        let summary = try await reconcile()
        #expect(summary.total == 0)
    }

    @Test func firstEnableQueuesEverything() async throws {
        let one = store.create(body: "one #swift", now: now)
        let two = store.create(body: "two", now: now)
        try await state.configure(vaultID: "vault")
        let summary = try await reconcile()
        #expect(summary.thoughts == 2 && summary.tags == 1 && summary.settings == 1 && summary.deletions == 0)
        #expect(!summary.ranOnMainThread)
        #expect(try await queued() == [.thought(one.id), .thought(two.id), .tag("swift"), .settings])
    }

    @Test func nothingIsQueuedOnceEverythingIsSynced() async throws {
        store.create(body: "one #swift", now: now)
        let gone = store.create(body: "gone", now: now)
        store.delete(gone, now: now.addingTimeInterval(1))
        try await state.configure(vaultID: "vault")
        _ = try await reconcile()
        try await markEverythingSynced(context: context, state: state, defaults: defaults)
        #expect(try await state.outboxCount() == 0)
        let summary = try await reconcile()
        #expect(summary.total == 0)
        #expect(try await queued().isEmpty)
    }

    @Test func editingOneThoughtRequeuesOnlyIt() async throws {
        let edited = store.create(body: "edit me", now: now)
        let viewed = store.create(body: "view me", now: now)
        let untouched = store.create(body: "leave me", now: now)
        try await state.configure(vaultID: "vault")
        try await markEverythingSynced(context: context, state: state, defaults: defaults)

        store.update(edited, body: "edited", blocks: [], intervalDays: nil, now: now.addingTimeInterval(10))
        #expect(try await reconcile().thoughts == 1)
        #expect(try await queued() == [.thought(edited.id)])

        try await markEverythingSynced(context: context, state: state, defaults: defaults)
        store.markViewed(viewed, now: now.addingTimeInterval(20))
        _ = try await reconcile()
        #expect(try await queued() == [.thought(viewed.id)])
        #expect(!(try await queued()).contains(.thought(untouched.id)))
    }

    @Test func aRecoloredTagAndASettingsChangeAreRequeued() async throws {
        store.create(body: "#swift #work", now: now)
        try await state.configure(vaultID: "vault")
        try await markEverythingSynced(context: context, state: state, defaults: defaults)
        let swift = try #require(try context.fetch(FetchDescriptor<ThoughtReps.Tag>()).first { $0.name == "swift" })
        store.setColor(swift, hex: "#3352D1", now: now.addingTimeInterval(5))
        AppSettings.recordDefaultIntervalChange(now: now.addingTimeInterval(6), defaults: defaults, sync: SyncState(location: .inMemory))
        _ = try await reconcile()
        #expect(try await queued() == [.tag("swift"), .settings])
    }

    @Test func aDeletedThoughtQueuesItsDeletionUntilSynced() async throws {
        let doomed = store.create(body: "doomed", now: now)
        store.create(body: "kept", now: now)
        try await state.configure(vaultID: "vault")
        try await markEverythingSynced(context: context, state: state, defaults: defaults)

        let id = doomed.id
        store.delete(doomed, now: now.addingTimeInterval(30))
        let summary = try await reconcile()
        #expect(summary.deletions == 1 && summary.thoughts == 0)
        #expect(try await queued() == [.thought(id)])

        try await markEverythingSynced(context: context, state: state, defaults: defaults)
        #expect(try await reconcile().total == 0)
    }

    @Test func manyTombstonesAcrossPages() async throws {
        for _ in 0..<1300 {
            context.insert(Tombstone(id: UUID(), kind: .thought, deletedAt: now))
        }
        try context.save()
        try await state.configure(vaultID: "vault")
        #expect(try await reconcile().deletions == 1300)
        try await markEverythingSynced(context: context, state: state, defaults: defaults)
        #expect(try await reconcile().total == 0)
    }

    @Test func manyThoughtsAcrossPages() async throws {
        for n in 0..<2300 {
            context.insert(Thought(body: "bulk \(n)", createdAt: now, nextDueAt: now))
        }
        try context.save()
        try await state.configure(vaultID: "vault")
        #expect(try await reconcile().thoughts == 2300)
        try await markEverythingSynced(context: context, state: state, defaults: defaults)
        #expect(try await reconcile().total == 0)
    }
}
