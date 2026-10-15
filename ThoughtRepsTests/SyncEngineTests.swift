import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync engine")
struct SyncEngineTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func pair(configA: SyncEngine.Configuration = .init(), configB: SyncEngine.Configuration = .init()) async throws -> (SyncDevice, SyncDevice) {
        (try await SyncDevice("A", server: server, config: configA), try await SyncDevice("B", server: server, config: configB))
    }

    func expectSame(_ a: SyncDevice, _ b: SyncDevice, _ message: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(try a.canonicalDump() == b.canonicalDump(), message, sourceLocation: sourceLocation)
    }

    // MARK: Propagation

    @Test func aCreatedThoughtReachesTheOtherDevice() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "hello #swift", intervalDays: 3, now: a.now(at(0)))
        let status = await a.sync()
        #expect(status.lastError == nil)
        #expect(status.pending == 0)
        await b.sync()
        let copy = try #require(try b.thought(thought.id))
        #expect(copy.body == "hello #swift")
        #expect(copy.intervalDays == 3)
        #expect(copy.sortedTags.map(\.name) == ["swift"])
        try expectSame(a, b)
        try await b.expectClean()
        #expect(try await b.state.outboxCount() == 0, "applying remote changes queues nothing")
    }

    @Test func editsPropagateAndBlocksFollow() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "one", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        a.store.update(thought, body: "two #tag", blocks: [BlockDraft(content: "block text #other")], intervalDays: 5, now: a.now(at(10)))
        await a.sync()
        await b.sync()
        let copy = try #require(try b.thought(thought.id))
        #expect(copy.body == "two #tag")
        #expect(copy.sortedBlocks.map(\.content) == ["block text #other"])
        #expect(copy.sortedTags.map(\.name) == ["other", "tag"])
        try expectSame(a, b)
        try await b.expectClean()
        try await a.expectClean()
    }

    @Test func scheduleStateAndCounterChangesPropagate() async throws {
        let (a, b) = try await pair()
        let fixed = a.store.create(body: "fixed", now: a.now(at(0)))
        let learner = a.store.create(body: "learn", learn: true, now: a.now(at(0)))
        let archived = a.store.create(body: "archived", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        let later = at(86_400 * 30)
        a.store.markViewed(fixed, now: a.now(later))
        a.store.setPinned(fixed, true, now: a.now(later))
        a.store.snooze(archived, days: 4, now: a.now(later))
        a.store.archive(archived, now: a.now(later.addingTimeInterval(1)))
        a.store.review(learner, gotIt: true, now: a.now(later))
        await a.sync()
        await b.sync()
        let fixedCopy = try #require(try b.thought(fixed.id))
        #expect(fixedCopy.isPinned)
        #expect(fixedCopy.viewCount == 1)
        #expect(try #require(try b.thought(archived.id)).isArchived)
        #expect(try #require(try b.thought(learner.id)).learnIntervalDays != nil)
        try expectSame(a, b)
        try await b.expectClean()
    }

    @Test func aViewOnOneDeviceDoesNotReuploadTheBody() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "body", now: a.now(at(0)))
        await a.sync()
        let contentKey = a.keys.recordKey(type: .thoughtContent, entityID: thought.id.uuidString)
        let metaKey = a.keys.recordKey(type: .thoughtMeta, entityID: thought.id.uuidString)
        await b.sync()
        b.store.markViewed(try #require(try b.thought(thought.id)), now: b.now(at(86_400 * 9)))
        await b.sync()
        #expect(await server.recordPushes[contentKey] == 1)
        #expect(await server.recordPushes[metaKey] == 2)
        await a.sync()
        try expectSame(a, b)
    }

    @Test func tagColorsAndTheDefaultIntervalPropagate() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "colorful #paint", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        let tag = try #require(thought.sortedTags.first)
        a.store.setColor(tag, hex: "#3352D1", now: a.now(at(60)))
        AppSettings.recordDefaultIntervalChange(now: a.now(at(61)), defaults: a.defaults, sync: a.state)
        a.defaults.set(14, forKey: AppSettings.Key.defaultIntervalDays)
        a.state.enqueue([.settings])
        await a.sync()
        await b.sync()
        let copy = try #require(try b.thought(thought.id)).sortedTags.first
        #expect(copy?.colorHex == "#3352D1")
        #expect(AppSettings.defaultIntervalDays(in: b.defaults) == 14)
        try expectSame(a, b)
    }

    @Test func aDeletionPropagatesWithATombstone() async throws {
        let (a, b) = try await pair()
        let keep = a.store.create(body: "keep", now: a.now(at(0)))
        let doomed = a.store.create(body: "doomed", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        a.store.delete(doomed, now: a.now(at(100)))
        await a.sync()
        await b.sync()
        #expect(try b.thought(doomed.id) == nil)
        #expect(try b.thought(keep.id) != nil)
        #expect(try b.tombstones().map(\.id) == [doomed.id])
        try expectSame(a, b)
        try await b.expectClean()
        #expect(try await b.state.outboxCount() == 0)
        #expect(await server.liveRecordCount == 2, "only keep's content and meta are live")
    }

    @Test func imagesAndFilesTravelOnceAndArriveBeforeTheirThought() async throws {
        let (a, b) = try await pair()
        let inline = newImage(5)
        let gallery = newImage(6)
        let file = fakeFile(7)
        let thought = a.store.create(
            body: "pictures\n" + ImageToken.token(for: inline.id),
            blocks: [BlockDraft(kind: .gallery, title: "G", images: [gallery]), fileBlock(file)],
            images: [inline], now: a.now(at(0))
        )
        #expect(thought.modelContext != nil)
        await a.sync()
        #expect(await server.blobs.count == 3)

        let events = await server.events
        let firstPush = try #require(events.firstIndex { if case .push = $0 { true } else { false } })
        let uploads = events.enumerated().filter { if case .putBlob = $0.element { true } else { false } }.map(\.offset)
        #expect(uploads.count == 3 && uploads.allSatisfy { $0 < firstPush }, "blobs go up before the records that reference them")

        await b.sync()
        let copy = try #require(try b.thought(thought.id))
        #expect((copy.images ?? []).count == 2)
        #expect((copy.files ?? []).count == 1)
        try expectSame(a, b)
        try await b.expectClean()

        a.store.update(thought, body: thought.body + " edited", blocks: RandomizedOperationTests.currentDrafts(of: thought), intervalDays: nil, now: a.now(at(50)))
        await a.sync()
        await b.sync()
        #expect(await server.blobPuts.values.allSatisfy { $0 == 1 }, "each blob is uploaded once")
        try expectSame(a, b)
    }

    // MARK: Pushing

    @Test func aNoOpEntryIsSkippedByBaseHash() async throws {
        let (a, _) = try await pair()
        let thought = a.store.create(body: "same", now: a.now(at(0)))
        await a.sync()
        let pushes = await server.pushCalls
        a.state.enqueue([.thought(thought.id)])
        let status = await a.sync()
        #expect(status.pending == 0)
        #expect(await server.pushCalls == pushes)
    }

    @Test func aConflictPullsMergesAndPushesAgain() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "shared", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        a.store.markViewed(thought, now: a.now(at(86_400 * 8)))
        b.store.setPinned(try #require(try b.thought(thought.id)), true, now: b.now(at(86_400 * 9)))
        // A gets its view in between B's pull and B's push.
        await server.beforeNextPush { [a] in await a.sync() }
        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(await server.conflicts == 1)
        await a.sync()
        let merged = try #require(try a.thought(thought.id))
        #expect(merged.isPinned && merged.viewCount == 1)
        try expectSame(a, b)
    }

    @Test func aLostResponseIsRecognizedWithoutRepushing() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "once", now: a.now(at(0)))
        await server.dropNextPushResponse()
        let failed = await a.sync()
        #expect(failed.lastError != nil)
        #expect(failed.pending == 1)
        let head = await server.headSeq
        let recovered = await a.sync()
        #expect(recovered.lastError == nil)
        #expect(recovered.pending == 0)
        #expect(await server.headSeq == head, "nothing was pushed twice")
        #expect(await server.pushCalls == 1)
        await b.sync()
        #expect(try b.thought(thought.id) != nil)
        try expectSame(a, b)
    }

    @Test func aLostResponseThenALaterEditPushesTheEditAgainstTheRemoteSeq() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "v1", now: a.now(at(0)))
        await server.dropNextPushResponse()
        await a.sync()
        a.store.update(thought, body: "v2", blocks: [], intervalDays: nil, now: a.now(at(10)))
        let status = await a.sync()
        #expect(status.lastError == nil)
        await b.sync()
        #expect(try #require(try b.thought(thought.id)).body == "v2")
        try expectSame(a, b)
    }

    @Test func aFailedCallBeforeCommitLeavesTheOutboxForTheNextCycle() async throws {
        let (a, b) = try await pair()
        a.store.create(body: "queued", now: a.now(at(0)))
        await server.failNextCall(after: 1)
        let failed = await a.sync()
        #expect(failed.lastError != nil)
        #expect(failed.pending == 1)
        await a.sync()
        await b.sync()
        try expectSame(a, b)
    }

    // MARK: Resync, epoch, failures

    @Test func aGoneCursorStartsOverWithoutLosingOrDuplicatingAnything() async throws {
        let (a, b) = try await pair()
        let shared = a.store.create(body: "shared", now: a.now(at(0)))
        let doomed = a.store.create(body: "doomed", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        let bCursor = try await b.state.cursor()
        // While B is away, A deletes a thought B never had a tombstone for, and the server forgets old tombstones.
        a.store.delete(doomed, now: a.now(at(10)))
        let other = a.store.create(body: "from A", now: a.now(at(11)))
        await a.sync()
        await server.prune(tombstonesBelow: await server.headSeq + 1)
        // B edits one thought and makes another, offline.
        b.store.update(try #require(try b.thought(shared.id)), body: "shared, edited on B", blocks: [], intervalDays: nil, now: b.now(at(20)))
        let created = b.store.create(body: "from B", now: b.now(at(21)))
        #expect(bCursor < (await server.prunedBeforeSeq))

        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(await server.pullCalls > 0)
        // B never saw the deletion, so it pushes `doomed` again; A still has the tombstone, ignores it and the
        // deletion goes back out, so everyone ends up without it.
        try await syncToQuiescence([a, b], server: server)
        let survivors = Set([shared.id, other.id, created.id])
        #expect(Set(try a.thoughts().map(\.id)) == survivors)
        #expect(Set(try b.thoughts().map(\.id)) == survivors)
        #expect(try #require(try a.thought(shared.id)).body == "shared, edited on B")
        #expect(await server.liveThoughtIDs(keys: a.keys, vaultID: SyncDevice.vaultID) == survivors)
        try expectSame(a, b)
        try await b.expectClean()
        try await a.expectClean()
    }

    @Test func aChangedEpochStopsSyncing() async throws {
        let (a, b) = try await pair()
        a.store.create(body: "one", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        await server.bumpEpoch()
        b.store.create(body: "two", now: b.now(at(5)))
        let status = await b.sync()
        #expect(status.attention == .epochChanged(known: 1, server: 2))
        #expect(status.phase == .stopped)
        #expect(await server.liveRecordCount == 2, "nothing was pushed after the epoch changed")
        let again = await b.sync()
        #expect(again.attention != nil)
        #expect(try await b.state.outboxCount() == 1)
    }

    @Test func aFailedApplyDoesNotAdvanceTheCursorAndTheNextCycleRetries() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "arrives late", now: a.now(at(0)))
        await a.sync()
        b.failSaves = 1
        let failed = await b.sync()
        #expect(failed.lastError != nil)
        #expect(try await b.state.cursor() == 0)
        #expect(try await b.state.recordCount() == 0)
        #expect(try b.thought(thought.id) == nil)
        let retried = await b.sync()
        #expect(retried.lastError == nil)
        #expect(try b.thought(thought.id) != nil)
        try expectSame(a, b)
        try await b.expectClean()
    }

    @Test func aLaterEditFromAClockThatRunsBehindStillWins() async throws {
        let server = server
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server, clockOffset: -5 * 3600)
        let thought = a.store.create(body: "start", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        a.store.update(thought, body: "A edit", blocks: [], intervalDays: nil, now: a.now(at(100)))
        await a.sync()
        await b.sync()
        #expect(SyncClock(defaults: b.defaults).highestSeen >= a.now(at(100)))

        let copy = try #require(try b.thought(thought.id))
        b.store.update(copy, body: "B edit, later in real life", blocks: [], intervalDays: nil, now: b.now(at(200)))
        #expect(copy.updatedAt > a.now(at(100)))
        b.store.setPinned(copy, true, now: b.now(at(201)))
        await b.sync()
        await a.sync()
        #expect(try #require(try a.thought(thought.id)).body == "B edit, later in real life")
        #expect(try #require(try a.thought(thought.id)).isPinned)
        try expectSame(a, b)
    }

    @Test func theSkewClockIsInertWithoutSyncAndSurvivesARelaunch() async throws {
        let (a, _) = try await pair()
        let clock = SyncClock(defaults: a.defaults)
        #expect(clock.highestSeen == .distantPast)
        #expect(clock.stamp(at(5)) == at(5))
        let thought = a.store.create(body: "plain", now: at(5))
        #expect(thought.updatedAt == at(5) && thought.scheduleChangedAt == at(5) && thought.stateChangedAt == at(5))
        clock.observe(at(100))
        #expect(SyncClock(defaults: a.defaults).highestSeen == at(100))
        #expect(SyncClock(defaults: a.defaults).stamp(at(5)) == at(100).addingTimeInterval(0.001))
        #expect(SyncClock(defaults: a.defaults).stamp(at(500)) == at(500))
        a.store.setPinned(thought, true, now: at(6))
        #expect(thought.stateChangedAt == at(100).addingTimeInterval(0.001))
    }

    // MARK: Deletion against edits

    @Test func anEditAfterADeletionBringsTheThoughtBack() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "contested", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        a.store.delete(thought, now: a.now(at(100)))
        await a.sync()
        // B is offline and edits after A's deletion.
        b.store.update(try #require(try b.thought(thought.id)), body: "contested, rewritten", blocks: [], intervalDays: nil, now: b.now(at(200)))
        await b.sync()
        await a.sync()
        #expect(try #require(try a.thought(thought.id)).body == "contested, rewritten")
        #expect(try a.tombstones().isEmpty)
        try expectSame(a, b)
        try await a.expectClean()
        try await b.expectClean()
    }

    @Test func anEditBeforeADeletionStaysDeleted() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "contested", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        b.store.update(try #require(try b.thought(thought.id)), body: "edited early", blocks: [], intervalDays: nil, now: b.now(at(50)))
        a.store.delete(thought, now: a.now(at(100)))
        await a.sync()
        await b.sync()
        await a.sync()
        #expect(try a.thought(thought.id) == nil)
        #expect(try b.thought(thought.id) == nil)
        try expectSame(a, b)
        try await b.expectClean()
    }

    @Test func aLocalDeletionOfAThoughtEditedElsewhereLaterComesBack() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "contested", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        b.store.update(try #require(try b.thought(thought.id)), body: "edited later", blocks: [], intervalDays: nil, now: b.now(at(200)))
        await b.sync()
        a.store.delete(thought, now: a.now(at(100)))
        await a.sync()
        await b.sync()
        await a.sync()
        #expect(try #require(try a.thought(thought.id)).body == "edited later")
        try expectSame(a, b)
        try await a.expectClean()
    }

    // MARK: Collisions and joining

    @Test func concurrentContentEditsEndUpWithTheLaterOne() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "base", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        a.store.update(thought, body: "from A", blocks: [], intervalDays: nil, now: a.now(at(100)))
        b.store.update(try #require(try b.thought(thought.id)), body: "from B", blocks: [], intervalDays: nil, now: b.now(at(200)))
        try await syncToQuiescence([a, b], server: server)
        #expect(try #require(try a.thought(thought.id)).body == "from B")
        try expectSame(a, b)
    }

    @Test func theContentResolverSeamPicksTheLaterEditAndBreaksTiesTheSameWayOnBothSides() {
        func content(_ body: String, _ updatedAt: Date) -> ThoughtContentRecord {
            ThoughtContentRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, body: body, createdAt: at(0), updatedAt: updatedAt, blocks: [], images: [])
        }
        let older = content("older", at(1))
        let newer = content("newer", at(2))
        #expect(ContentResolver.resolve(base: nil, local: older, remote: newer) == .takeRemote)
        #expect(ContentResolver.resolve(base: older, local: newer, remote: older) == .keepLocal)
        let x = content("x", at(3))
        let y = content("y", at(3))
        let forward = ContentResolver.resolve(base: nil, local: x, remote: y)
        let backward = ContentResolver.resolve(base: nil, local: y, remote: x)
        #expect(forward != backward, "exactly one side takes the other's version")
    }

    @Test func joiningWithExistingThoughtsAddsThemUp() async throws {
        let (a, b) = try await pair()
        let fromA = a.store.create(body: "A's thought", now: a.now(at(0)))
        let shared = a.store.create(body: "both have this", now: a.now(at(1)))
        await a.sync()
        // B existed before joining: its own thought, and an older copy of a shared one.
        let fromB = b.store.create(body: "B's thought", now: b.now(at(2)))
        let older = Thought(body: "both have this (older)", createdAt: at(-100), nextDueAt: at(86_400 * 7))
        older.id = shared.id
        b.context.insert(older)
        try b.context.save()
        try await b.reconcile()
        try await syncToQuiescence([a, b], server: server)
        #expect(Set(try a.thoughts().map(\.id)) == [fromA.id, shared.id, fromB.id])
        #expect(try #require(try b.thought(shared.id)).body == "both have this")
        try expectSame(a, b)
        try await a.expectClean()
        try await b.expectClean()
    }

    @Test func aRecordForAThoughtNotHereYetWaitsForItsPartner() async throws {
        let (a, b) = try await pair(configB: .paged(pull: 1))
        let thought = a.store.create(body: "v1", now: a.now(at(0)))
        await a.sync()
        // The meta record is older than the content record, so a one-record page brings the meta first.
        a.store.update(thought, body: "v2", blocks: [], intervalDays: nil, now: a.now(at(10)))
        await a.sync()
        await server.failNextCall(after: 1)
        let interrupted = await b.sync()
        #expect(interrupted.lastError != nil)
        #expect(try b.thought(thought.id) == nil)
        #expect(try await b.state.heldCount() == 1)
        await b.sync()
        #expect(try await b.state.heldCount() == 0)
        #expect(try #require(try b.thought(thought.id)).body == "v2")
        try expectSame(a, b)
        try await b.expectClean()
    }

    @Test func aRejectedThoughtGetsNoBaseAndStaysHeldForALaterRetry() async throws {
        let (a, b) = try await pair()
        let shared = UUID()
        let theirs = a.store.create(
            body: "theirs " + ImageToken.token(for: shared), images: [ImageDraft(id: shared, processed: fakeImage(1))], now: a.now(at(0))
        )
        b.store.create(body: "mine " + ImageToken.token(for: shared), images: [ImageDraft(id: shared, processed: fakeImage(1))], now: b.now(at(1)))
        await a.sync()
        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(try b.thought(theirs.id) == nil)
        let contentKey = b.keys.recordKey(type: .thoughtContent, entityID: theirs.id.uuidString)
        #expect(try await b.state.record(forKey: contentKey) == nil, "no base, so it doesn't count as synced")
        #expect(try await b.state.heldCount() == 2)
    }
}
