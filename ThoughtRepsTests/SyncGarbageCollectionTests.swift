import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync garbage collection and quota")
struct SyncGarbageCollectionTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    let day: TimeInterval = 24 * 3600

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func device(_ name: String = "A", clock: TestClock? = nil, config: SyncEngine.Configuration = .init()) async throws -> SyncDevice {
        let device = try await SyncDevice(name, server: server, config: config)
        if let clock { device.makeEngine(config: config, now: { clock.now }) }
        return device
    }

    /// Two syncs: the first pulls what the device pushed, so the second ends with the cursor at the server's head.
    @discardableResult
    func settle(_ device: SyncDevice) async -> SyncEngine.Status {
        await device.sync()
        return await device.sync()
    }

    func blobName(_ device: SyncDevice, image: ImageDraft) -> String { device.keys.blobName(kind: .image, id: image.id) }

    // MARK: When a run starts

    @Test func aCleanCycleAsksForARunWithTheLiveListAndTheCursor() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        let inline = newImage(1)
        let gallery = newImage(2)
        let file = fakeFile(3)
        a.store.create(
            body: "pictures\n" + ImageToken.token(for: inline.id),
            blocks: [BlockDraft(kind: .gallery, images: [gallery]), fileBlock(file)], images: [inline], now: a.now(at(0))
        )
        await a.sync()
        #expect(await server.garbageCollections.isEmpty, "the first cycle pushed, so the cursor is behind the head")

        let status = await a.sync()
        #expect(status.lastError == nil && status.attention == nil)
        let calls = await server.garbageCollections
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        let cursor = try await a.state.cursor()
        let head = await server.headSeq
        #expect(call.asOfSeq == cursor && cursor == head)
        #expect(call.epoch == (await server.epoch))
        let expected = [
            a.keys.blobName(kind: .image, id: inline.id), a.keys.blobName(kind: .image, id: gallery.id), a.keys.blobName(kind: .file, id: file.id),
        ].sorted()
        #expect(call.names == expected)
        #expect(call.liveList == Data(expected.map { $0 + "\n" }.joined().utf8))
        let log = try await a.state.garbageCollectionLog()
        #expect(log.lastOutcome == .started && log.lastStartedAt == t0 && log.lastAttemptAt == t0 && log.retryNotBefore == nil)
    }

    @Test func theLiveListNamesArchivedThoughtsImagesAndNotPointerBlobs() async throws {
        let a = try await device()
        let archived = newImage(1)
        let thought = a.store.create(body: "old\n" + ImageToken.token(for: archived.id), images: [archived], now: a.now(at(0)))
        a.store.archive(thought, now: a.now(at(1)))
        let live = newImage(2)
        a.store.create(body: "live\n" + ImageToken.token(for: live.id), images: [live], now: a.now(at(2)))
        a.store.create(body: String(repeating: "large ", count: 15_000), now: a.now(at(3)))
        await settle(a)

        let pointers = await server.blobReferences(keys: a.keys, vaultID: SyncDevice.vaultID).pointers
        #expect(pointers.count == 1, "the large record is stored as a blob")
        let call = try #require(await server.garbageCollections.first)
        #expect(call.names == [a.keys.blobName(kind: .image, id: archived.id), a.keys.blobName(kind: .image, id: live.id)].sorted())
        #expect(Set(call.names).isDisjoint(with: pointers))
        #expect(call.liveList.count == 2 * 44 && call.names.allSatisfy { $0.utf8.count == 43 })
    }

    @Test func aLibraryWithNoImagesSendsAnEmptyList() async throws {
        let a = try await device()
        a.store.create(body: "text only", now: a.now(at(0)))
        await settle(a)
        let call = try #require(await server.garbageCollections.first)
        #expect(call.liveList.isEmpty)
    }

    @Test func theListIsSortedAndWithoutRepeats() {
        let list = SyncEngine.liveList(names: ["b", "a", "b", "c", "a"])
        #expect(String(decoding: list, as: UTF8.self) == "a\nb\nc\n")
        #expect(SyncEngine.liveList(names: []).isEmpty)
    }

    @Test func aLibraryOverTheListLimitSkipsTheRun() async throws {
        var config = SyncEngine.Configuration()
        config.maxLiveListNames = 1
        let a = try await device(config: config)
        let one = newImage(1)
        let two = newImage(2)
        a.store.create(body: "a\n" + ImageToken.token(for: one.id), images: [one], now: a.now(at(0)))
        a.store.create(body: "b\n" + ImageToken.token(for: two.id), images: [two], now: a.now(at(1)))
        let status = await settle(a)
        #expect(await server.garbageCollections.isEmpty)
        #expect(status.lastError == nil && status.attention == nil)
        let log = try await a.state.garbageCollectionLog()
        #expect(log.lastOutcome == .tooManyBlobs && log.lastStartedAt == nil)
    }

    @Test func aTransportWithoutBlobsNeverAsks() async throws {
        let a = try await device()
        a.transport = NoBlobsTransport(base: server)
        a.makeEngine()
        a.store.create(body: "text", now: a.now(at(0)))
        await settle(a)
        #expect(await server.garbageCollections.isEmpty)
        #expect(try await a.state.garbageCollectionLog() == GarbageCollectionLog())
    }

    // MARK: Only when nothing is missing

    @Test func aQueuedChangeHoldsTheRunBack() async throws {
        let a = try await device()
        let image = newImage(1)
        a.store.create(body: "pic\n" + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        try a.context.fetch(FetchDescriptor<ImageAsset>()).forEach { $0.data = nil }
        try a.context.save()
        let status = await settle(a)
        #expect(status.missingAttachments == 1 && status.pending == 1 && status.lastError == nil)
        #expect(await server.garbageCollections.isEmpty, "a thought whose image bytes are gone stays queued")
    }

    @Test func aThoughtHeldForTheStorageLimitDoesNotHoldTheRunBackAndTheRunIsDueAtOnce() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        a.store.create(body: "first", now: a.now(at(0)))
        await settle(a)
        #expect(await server.garbageCollections.count == 1)

        clock.advance(by: 3601)
        await server.limitBlobBytes(to: 10)
        let image = newImage(1)
        a.store.create(body: "pic\n" + ImageToken.token(for: image.id), images: [image], now: a.now(at(3601)))
        let held = await settle(a)
        #expect(held.quotaExceededThoughts == 1 && held.pending == 1)
        let calls = await server.garbageCollections
        #expect(calls.count == 2, "far short of a week, but the storage limit asks for a run")
        #expect(calls.last?.names == [a.keys.blobName(kind: .image, id: image.id)], "the held thought's image is on the list")
        let log = try await a.state.garbageCollectionLog()
        #expect(log.lastOutcome == .started && log.quotaHitAt == nil)

        await server.limitBlobBytes(to: nil)
        let released = await a.sync()
        #expect(released.quotaExceededThoughts == 0 && released.pending == 0, "the held thought goes out on the next cycle")
    }

    @Test func aQuotaRunIsNotAskedForAgainWithinAnHourOfAFailedOne() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        await server.limitBlobBytes(to: 10)
        let image = newImage(1)
        a.store.create(body: "pic\n" + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        await server.answerGarbageCollection(.stale)
        await settle(a)
        #expect(await server.garbageCollections.count == 1)
        #expect(try await a.state.garbageCollectionLog().quotaHitAt != nil)
        clock.advance(by: 3599)
        await a.sync()
        #expect(await server.garbageCollections.count == 1)
        clock.advance(by: 1)
        await a.sync()
        #expect(await server.garbageCollections.count == 2)
    }

    @Test func aRateLimitedRunStaysOutUntilTheServerAllowsIt() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        await server.limitBlobBytes(to: 10)
        let image = newImage(1)
        a.store.create(body: "pic\n" + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        await server.answerGarbageCollection(.rateLimited(retryAfterSeconds: 7200))
        await settle(a)
        clock.advance(by: 7199)
        await a.sync()
        #expect(await server.garbageCollections.count == 1, "the stored rate limit outlasts the retry gap")
        clock.advance(by: 1)
        await a.sync()
        #expect(await server.garbageCollections.count == 2)
    }

    @Test func otherQueuedEntriesStillHoldTheRunBackAlongsideAQuotaHeldOne() async throws {
        let a = try await device()
        await server.limitBlobBytes(to: 10)
        let image = newImage(1)
        a.store.create(body: "pic\n" + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        let missing = newImage(2)
        a.store.create(body: "gone\n" + ImageToken.token(for: missing.id), images: [missing], now: a.now(at(1)))
        try a.context.fetch(FetchDescriptor<ImageAsset>()).filter { $0.id == missing.id }.forEach { $0.data = nil }
        try a.context.save()
        let status = await settle(a)
        #expect(status.quotaExceededThoughts == 1 && status.missingAttachments == 1 && status.pending == 2)
        #expect(await server.garbageCollections.isEmpty)
    }

    @Test func aRecordThisVersionCannotReadHoldsTheRunBack() async throws {
        let a = try await device()
        let id = UUID()
        let recordKey = a.keys.recordKey(type: .thoughtMeta, entityID: id.uuidString)
        _ = await server.inject(
            recordKey: recordKey,
            payload: try SyncCrypto.seal(Data(#"{"v":2}"#.utf8), vaultID: SyncDevice.vaultID, recordKey: recordKey, payloadVersion: 2, keys: a.keys)
        )
        let status = await settle(a)
        #expect(status.updateRequired)
        #expect(await server.garbageCollections.isEmpty)
    }

    @Test func aPointerWhoseBlobIsMissingHoldsTheRunBack() async throws {
        let a = try await device()
        let recordKey = a.keys.recordKey(type: .thoughtContent, entityID: UUID().uuidString)
        _ = await server.inject(recordKey: recordKey, payload: SyncCrypto.pointer(toBlob: String(repeating: "Z", count: 43)))
        let status = await settle(a)
        #expect(status.blockedThoughts == 1)
        #expect(try await a.state.parkedPointerCount() == 1)
        #expect(await server.garbageCollections.isEmpty)
    }

    @Test func aThoughtWhoseBlobsAreMissingHoldsTheRunBackUntilTheyReturn() async throws {
        let a = try await device("A")
        let b = try await device("B")
        let image = newImage(1)
        a.store.create(body: "pic\n" + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        await a.sync()
        let saved = await server.removeAllBlobs()
        let status = await b.sync()
        #expect(status.blockedThoughts == 1)
        #expect(try await b.state.heldCount() > 0)
        #expect(await server.garbageCollections.isEmpty)

        await server.restoreBlobs(saved)
        await b.sync()
        let call = try #require(await server.garbageCollections.first)
        #expect(call.names == [a.keys.blobName(kind: .image, id: image.id)])
    }

    @Test func aCursorBehindTheServersHeadHoldsTheRunBack() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        a.store.create(body: "one", now: a.now(at(0)))
        await settle(a)
        #expect(await server.garbageCollections.count == 1)
        clock.advance(by: 8 * day)
        await server.afterNextPullQuery { [server] in
            _ = await server.inject(recordKey: "later-" + UUID().uuidString.lowercased(), payload: Data("TR00 other".utf8))
        }
        await a.sync()
        #expect(await server.garbageCollections.count == 1, "another device pushed after the pull, so a run is due but not asked for")
    }

    // MARK: Spacing

    @Test func aRunIsAskedForAtMostOnceAWeek() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        a.store.create(body: "one", now: a.now(at(0)))
        await settle(a)
        #expect(await server.garbageCollections.count == 1)

        clock.advance(by: 7 * day - 1)
        await a.sync()
        #expect(await server.garbageCollections.count == 1, "a second short of a week")
        clock.advance(by: 1)
        await a.sync()
        #expect(await server.garbageCollections.count == 2)
        #expect(try await a.state.garbageCollectionLog().lastStartedAt == t0.addingTimeInterval(7 * day))
        await a.sync()
        #expect(await server.garbageCollections.count == 2)
    }

    @Test func theLastRunSurvivesARelaunchOfTheEngine() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        await settle(a)
        #expect(await server.garbageCollections.count == 1)
        a.makeEngine(now: { clock.now })
        clock.advance(by: day)
        await a.sync()
        #expect(await server.garbageCollections.count == 1)
    }

    @Test func aClockSetBackBehindTheLastRunDoesNotBlockTheNext() {
        let log = GarbageCollectionLog(lastStartedAt: t0, retryNotBefore: nil, lastAttemptAt: t0, lastOutcome: .started)
        #expect(!log.isDue(at: t0.addingTimeInterval(3 * day)))
        #expect(log.isDue(at: t0.addingTimeInterval(7 * day)))
        #expect(log.isDue(at: t0.addingTimeInterval(-30 * day)))
        #expect(GarbageCollectionLog().isDue(at: t0))
        let limited = GarbageCollectionLog(lastStartedAt: nil, retryNotBefore: t0.addingTimeInterval(7200), lastAttemptAt: t0, lastOutcome: .rateLimited)
        #expect(!limited.isDue(at: t0.addingTimeInterval(7199)) && limited.isDue(at: t0.addingTimeInterval(7200)))
        let failed = GarbageCollectionLog(lastStartedAt: nil, retryNotBefore: nil, lastAttemptAt: t0, lastOutcome: .failed)
        #expect(!failed.isDue(at: t0.addingTimeInterval(3599)) && failed.isDue(at: t0.addingTimeInterval(3600)))
        let wanted = GarbageCollectionLog(lastStartedAt: t0, retryNotBefore: nil, lastAttemptAt: t0.addingTimeInterval(10), lastOutcome: .started, quotaHitAt: t0.addingTimeInterval(5))
        #expect(wanted.isDue(at: t0.addingTimeInterval(11)), "a storage limit refusal skips the week")
    }

    // MARK: What the server answers

    @Test func aStaleAnswerIsTriedAgainOnTheNextCleanCycle() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        await server.answerGarbageCollection(.stale)
        let status = await settle(a)
        #expect(status.lastError == nil && status.attention == nil)
        let log = try await a.state.garbageCollectionLog()
        #expect(log.lastOutcome == .stale && log.lastStartedAt == nil)
        await a.sync()
        #expect(await server.garbageCollections.count == 1, "not again within the hour")
        clock.advance(by: 3600)
        await a.sync()
        #expect(await server.garbageCollections.count == 2)
        #expect(try await a.state.garbageCollectionLog().lastOutcome == .started)
    }

    @Test func aMissingListIsTriedAgainOnTheNextCleanCycle() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        await server.answerGarbageCollection(.liveListMissing)
        let status = await settle(a)
        #expect(status.lastError == nil && status.attention == nil)
        #expect(try await a.state.garbageCollectionLog().lastOutcome == .liveListMissing)
        clock.advance(by: 3600)
        await a.sync()
        #expect(try await a.state.garbageCollectionLog().lastOutcome == .started)
    }

    @Test func aRateLimitIsRespectedUntilItPasses() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        await server.answerGarbageCollection(.rateLimited(retryAfterSeconds: 2400))
        let status = await settle(a)
        #expect(status.lastError == nil && status.attention == nil)
        var log = try await a.state.garbageCollectionLog()
        #expect(log.lastOutcome == .rateLimited && log.retryNotBefore == t0.addingTimeInterval(2400) && log.lastStartedAt == nil)

        clock.advance(by: 3599)
        await a.sync()
        #expect(await server.garbageCollections.count == 1, "not before the hour's gap, which is longer than this limit")
        clock.advance(by: 1)
        await a.sync()
        #expect(await server.garbageCollections.count == 2)
        log = try await a.state.garbageCollectionLog()
        #expect(log.lastOutcome == .started && log.retryNotBefore == nil)
    }

    @Test func aBusyServerOrAnOutageIsTriedAgainAndNeverFailsTheCycle() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        await server.failGarbageCollection(with: .unavailable)
        let status = await settle(a)
        #expect(status.lastError == nil && status.attention == nil && status.phase == .idle)
        let log = try await a.state.garbageCollectionLog()
        #expect(log.lastOutcome == .failed && log.lastStartedAt == nil)
        clock.advance(by: 3600)
        await a.sync()
        #expect(try await a.state.garbageCollectionLog().lastOutcome == .started)
    }

    @Test func aRefusalOfTheRunNeverStopsTheEngine() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        for status in [400, 404, 410] {
            await server.failGarbageCollection(with: .refused(status: status, message: "no"))
            let result = await a.sync()
            #expect(result.attention == nil && result.lastError == nil, "\(status)")
            clock.advance(by: 3600)
        }
        #expect(try await a.state.garbageCollectionLog().lastOutcome == .failed)
        a.store.create(body: "still syncing", now: a.now(at(0)))
        let result = await a.sync()
        #expect(result.attention == nil && result.pending == 0)
        #expect(await server.rows.count == 3, "the thought's two records and the settings reached the server")
    }

    @Test func aChangedEpochDuringTheRunStopsSyncingLikeAnyOtherCall() async throws {
        let clock = TestClock(t0)
        let a = try await device(clock: clock)
        await settle(a)
        let known = try #require(try await a.state.epoch())
        await server.failGarbageCollection(with: .epochChanged(server: known + 1))
        clock.advance(by: 8 * day)
        let status = await a.sync()
        #expect(status.attention == .epochChanged(known: known, server: known + 1))
    }

    // MARK: Quota

    @Test func aThoughtOverTheStorageLimitIsHeldWhileTheRestSyncAndGoesOutOnceThereIsRoom() async throws {
        let (a, b) = (try await device("A"), try await device("B"))
        await server.limitBlobBytes(to: 10)
        let image = newImage(1)
        let heavy = a.store.create(body: "pic\n" + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        let light = a.store.create(body: "plain", now: a.now(at(1)))
        let held = await a.sync()
        #expect(held.lastError == nil && held.attention == nil)
        #expect(held.quotaExceededThoughts == 1 && held.pending == 1)
        #expect(held.blobQuota == SyncEngine.BlobQuota(usedBytes: 0, limitBytes: 10))
        let contentKey = a.keys.recordKey(type: .thoughtContent, entityID: light.id.uuidString)
        #expect(await server.rows[contentKey] != nil, "the other thought went out")
        #expect(await server.rows[a.keys.recordKey(type: .thoughtContent, entityID: heavy.id.uuidString)] == nil)

        let still = await a.sync()
        #expect(still.quotaExceededThoughts == 1, "retried every cycle")
        await server.limitBlobBytes(to: nil)
        let released = await a.sync()
        #expect(released.quotaExceededThoughts == 0 && released.blobQuota == nil && released.pending == 0)
        await b.sync()
        #expect((try #require(try b.thought(heavy.id)).images ?? []).count == 1)
    }

    @Test func aRecordBlobOverTheStorageLimitHoldsItsThoughtToo() async throws {
        let a = try await device()
        await server.limitBlobBytes(to: 100)
        let large = a.store.create(body: String(repeating: "large ", count: 15_000), now: a.now(at(0)))
        a.store.create(body: "plain", now: a.now(at(1)))
        let held = await a.sync()
        #expect(held.lastError == nil && held.attention == nil)
        #expect(held.quotaExceededThoughts == 1 && held.pending == 1)
        #expect(await server.rows[a.keys.recordKey(type: .thoughtContent, entityID: large.id.uuidString)] == nil)
        await server.limitBlobBytes(to: nil)
        let released = await a.sync()
        #expect(released.quotaExceededThoughts == 0 && released.pending == 0)
        #expect(await server.rows[a.keys.recordKey(type: .thoughtContent, entityID: large.id.uuidString)] != nil)
    }

    @Test func theHeldCountIsPartOfTheHeadCheck() async throws {
        let a = try await device()
        await server.limitBlobBytes(to: 10)
        let image = newImage(1)
        a.store.create(body: "pic\n" + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        await a.sync()
        await a.sync()
        let calls = await server.headCalls
        let moved = await a.engine.syncIfHeadMoved()
        #expect(!moved, "a held thought alone doesn't start a cycle")
        #expect(await server.headCalls == calls + 1)
    }

    // MARK: Image checks

    @Test func aThoughtsBlobsGoStraightToPutBlobOnEveryPushOfIt() async throws {
        let a = try await device()
        let image = newImage(1)
        let thought = a.store.create(body: "pic\n" + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        await a.sync()
        #expect(await server.blobPutAttempts == 1)
        a.store.update(thought, body: thought.body + " edited", blocks: RandomizedOperationTests.currentDrafts(of: thought), intervalDays: nil, now: a.now(at(10)))
        await a.sync()
        #expect(await server.blobPutAttempts == 2, "the server is asked again, and says present")
        #expect(await server.blobPuts.values.allSatisfy { $0 == 1 }, "the bytes still go up once")
        #expect(await server.hasBlobCalls == 0, "no separate check for the blob")
    }

    // MARK: Randomized

    nonisolated static let seeds: [UInt64] = Array(1...12)

    /// Three devices create, rewrite (dropping their images), archive and delete thoughts with images, galleries and files,
    /// sync with failures, and the clock jumps past a week now and then so runs are asked for in the middle of it all.
    /// Whenever a run is accepted (the head is what the list was built at), the list must name every blob the vault's
    /// records use, and never a pointer's blob.
    @Test(arguments: seeds)
    func everyAcceptedListNamesWhatTheVaultUses(seed: UInt64) async throws {
        let keys = try SyncKeys(vaultKey: SyncDevice.vaultKey)
        await server.watchBlobReferences(keys: keys, vaultID: SyncDevice.vaultID)
        let offsets: [TimeInterval] = [0, -3 * 3600, 1800]
        let clocks = offsets.map { TestClock(t0.addingTimeInterval($0)) }
        var devices: [SyncDevice] = []
        for index in 0..<3 {
            let config = SyncEngine.Configuration.paged(pull: [2, 5, 50][index], push: [3, 10, 49][index])
            let device = try await SyncDevice("D\(index)", server: server, clockOffset: offsets[index], config: config)
            let clock = clocks[index]
            device.makeEngine(config: config, now: { clock.now })
            devices.append(device)
        }
        var rng = SeededGenerator(seed: seed)
        var now = t0

        for _ in 0..<120 {
            now = now.addingTimeInterval(Double(Int.random(in: 1...90, using: &rng)))
            if Int.random(in: 0..<20, using: &rng) == 0 { now = now.addingTimeInterval(8 * day) }
            for (index, device) in devices.enumerated() { clocks[index].set(device.now(now)) }
            let index = Int.random(in: 0..<3, using: &rng)
            let device = devices[index]
            let t = device.now(now)
            let all = try device.thoughts().sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            let target = all.randomElement(using: &rng)
            switch Int.random(in: 0..<14, using: &rng) {
            case 0, 1, 2:
                var body = RandomizedOperationTests.randomBody(&rng)
                var images: [ImageDraft] = []
                if Int.random(in: 0..<2, using: &rng) == 0 {
                    let image = newImage(UInt8.random(in: 0...255, using: &rng))
                    images = [image]
                    body += "\n" + ImageToken.token(for: image.id)
                }
                if Int.random(in: 0..<12, using: &rng) == 0 { body += "\n" + String(repeating: "large ", count: 15_000) }
                var blocks: [BlockDraft] = []
                if Int.random(in: 0..<3, using: &rng) == 0 { blocks.append(BlockDraft(kind: .gallery, images: [newImage(UInt8.random(in: 0...255, using: &rng))])) }
                if Int.random(in: 0..<4, using: &rng) == 0 { blocks.append(fileBlock(fakeFile(UInt8.random(in: 0...255, using: &rng)))) }
                device.store.create(body: body, blocks: blocks, images: images, intervalDays: nil, now: t)
            case 3, 4:
                if let target {
                    device.store.update(target, body: RandomizedOperationTests.randomBody(&rng), blocks: [], images: [], intervalDays: nil, now: t)
                }
            case 5:
                if let target { device.store.delete(target, now: t) }
            case 6:
                if let target { device.store.archive(target, now: t) }
            case 7:
                if let target, target.isArchived { device.store.restore(target, now: t) }
            default:
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: await server.failNextCall(after: Int.random(in: 0..<4, using: &rng))
                case 1: await server.dropNextPushResponse()
                default: break
                }
                await device.sync()
                await server.clearFailures()
            }
        }

        await server.clearFailures()
        now = now.addingTimeInterval(8 * day)
        for (index, device) in devices.enumerated() { clocks[index].set(device.now(now)) }
        try await syncToQuiescence(devices, server: server, maxRounds: 25)
        for device in devices { await device.sync() }

        let calls = await server.garbageCollections
        var accepted = 0
        for call in calls {
            let names = call.names
            #expect(names == Array(Set(names)).sorted(), "seed \(seed): sorted, without repeats")
            #expect(names.allSatisfy { $0.utf8.count == 43 }, "seed \(seed)")
            guard call.asOfSeq == call.headSeq else { continue }
            accepted += 1
            let inUse = try #require(call.inUse)
            #expect(inUse.isSubset(of: Set(names)), "seed \(seed): a blob in use was left off the list: \(inUse.subtracting(names))")
            #expect(Set(names).isDisjoint(with: try #require(call.pointerBlobs)), "seed \(seed): a pointer's blob was named")
        }
        #expect(accepted > 0, "seed \(seed): no run was ever accepted")
        for device in devices {
            #expect(try await device.state.outboxCount() == 0, "seed \(seed): \(device.name) still has queued changes")
            let status = await device.engine.status
            #expect(status.lastError == nil && status.attention == nil, "seed \(seed): \(device.name) \(status)")
            try await device.expectClean("seed \(seed)")
        }
        let last = try #require(calls.last { $0.asOfSeq == $0.headSeq })
        #expect(Set(last.names) == last.inUse, "seed \(seed): at quiescence the list is exactly what the vault uses")
    }
}

/// Everything forwarded to the fake server except blob support.
struct NoBlobsTransport: SyncTransport {
    let base: FakeSyncServer
    var supportsBlobs: Bool { false }
    func push(_ records: [PushRecord], epoch: Int64) async throws -> PushResult { try await base.push(records, epoch: epoch) }
    func pull(after cursor: Int64, limit: Int) async throws -> PullPage { try await base.pull(after: cursor, limit: limit) }
    func head() async throws -> SyncHead { try await base.head() }
    func putBlob(name: String, data: Data, epoch: Int64) async throws { throw SyncTransportError.unsupported }
    func getBlob(name: String, epoch: Int64, maxBytes: Int) async throws -> Data { throw SyncTransportError.unsupported }
    func hasBlob(name: String, epoch: Int64) async throws -> Bool { throw SyncTransportError.unsupported }
}
