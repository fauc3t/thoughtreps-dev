import Foundation
import SwiftData
import Testing
import os
@testable import ThoughtReps

/// Counts how often the engine asks the store to reconcile.
final class ReconcileCountingLocal: SyncLocalStore, @unchecked Sendable {
    private let inner: SyncLocalStore
    private let count = OSAllocatedUnfairLock(initialState: 0)
    init(_ inner: SyncLocalStore) { self.inner = inner }
    var reconciles: Int { count.withLock { $0 } }
    func snapshots(of entities: [SyncEntity]) async throws -> [SyncSnapshot] { try await inner.snapshots(of: entities) }
    func blobBytes(_ refs: [BlobRef]) async throws -> [BlobRef: Data] { try await inner.blobBytes(refs) }
    func missingBlobs(for contents: [ThoughtContentRecord]) async throws -> Set<BlobRef> { try await inner.missingBlobs(for: contents) }
    func apply(_ batch: RemoteBatch, now: Date) async -> RemoteOutcome { await inner.apply(batch, now: now) }
    func allBlobRefs(limit: Int) async throws -> [BlobRef]? { try await inner.allBlobRefs(limit: limit) }
    func reconcile() async {
        count.withLock { $0 += 1 }
        await inner.reconcile()
    }
}

/// Runs `hook` once, just before the engine first asks for the snapshots to push.
final class BeforeSnapshotsLocal: SyncLocalStore, @unchecked Sendable {
    private let inner: SyncLocalStore
    private let hook = OSAllocatedUnfairLock<(@Sendable () async -> Void)?>(initialState: nil)
    init(_ inner: SyncLocalStore, hook: @escaping @Sendable () async -> Void) {
        self.inner = inner
        self.hook.withLock { $0 = hook }
    }
    func snapshots(of entities: [SyncEntity]) async throws -> [SyncSnapshot] {
        if let run = hook.withLock({ state -> (@Sendable () async -> Void)? in defer { state = nil }; return state }) { await run() }
        return try await inner.snapshots(of: entities)
    }
    func blobBytes(_ refs: [BlobRef]) async throws -> [BlobRef: Data] { try await inner.blobBytes(refs) }
    func missingBlobs(for contents: [ThoughtContentRecord]) async throws -> Set<BlobRef> { try await inner.missingBlobs(for: contents) }
    func apply(_ batch: RemoteBatch, now: Date) async -> RemoteOutcome { await inner.apply(batch, now: now) }
    func allBlobRefs(limit: Int) async throws -> [BlobRef]? { try await inner.allBlobRefs(limit: limit) }
    func reconcile() async { await inner.reconcile() }
}

@MainActor
@Suite("Sync review fixes")
struct SyncReviewFixTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func pair(configA: SyncEngine.Configuration = .init(), configB: SyncEngine.Configuration = .init()) async throws -> (SyncDevice, SyncDevice) {
        (try await SyncDevice("A", server: server, config: configA), try await SyncDevice("B", server: server, config: configB))
    }

    func expectSame(_ a: SyncDevice, _ b: SyncDevice, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(try a.canonicalDump() == b.canonicalDump(), sourceLocation: sourceLocation)
    }

    func futureMagic(_ magic: String, from frame: Data) -> Data {
        var future = frame
        future.replaceSubrange(0..<4, with: Data(magic.utf8))
        return future
    }

    // MARK: Unrecognized magics

    @Test func aRecordInAFutureFrameIsParkedAndSyncingGoesOn() async throws {
        let (a, b) = try await pair()
        let plain = Data(#"{"data":{},"deleted":false,"type":"settings","v":1}"#.utf8)
        for (index, magic) in ["TRS2", "TRX9"].enumerated() {
            let key = "future-\(index)"
            let frame = try SyncCrypto.seal(plain, vaultID: SyncDevice.vaultID, recordKey: key, payloadVersion: 1, keys: b.keys)
            _ = await server.inject(recordKey: key, payload: futureMagic(magic, from: frame))
        }
        var newGeneration = try SyncCrypto.seal(plain, vaultID: SyncDevice.vaultID, recordKey: "rotated", payloadVersion: 1, keys: b.keys)
        newGeneration[4] = 2
        _ = await server.inject(recordKey: "rotated", payload: newGeneration)
        let thought = a.store.create(body: "ordinary", now: a.now(at(0)))
        await a.sync()

        let status = await b.sync()
        #expect(status.lastError == nil && status.attention == nil)
        #expect(status.updateRequired)
        #expect(try await b.state.parkedCount() == 3)
        #expect(try await b.state.cursor() == (await server.headSeq))
        #expect(try b.thought(thought.id) != nil)
    }

    @Test func aFutureFrameStaysParkedWhileTheVersionIsUnchanged() async throws {
        let b = try await SyncDevice("B", server: server)
        let plain = Data(#"{"data":{},"deleted":false,"type":"settings","v":1}"#.utf8)
        let frame = try SyncCrypto.seal(plain, vaultID: SyncDevice.vaultID, recordKey: "future", payloadVersion: 1, keys: b.keys)
        _ = await server.inject(recordKey: "future", payload: futureMagic("TRS2", from: frame))
        #expect(await b.sync().updateRequired)
        #expect(await b.sync().lastError == nil)
        #expect(try await b.state.parkedCount() == 1)
    }

    @Test func aPointerToABlobInAFutureFrameIsParkedAsUpdateRequiredNotBlocked() async throws {
        let b = try await SyncDevice("B", server: server)
        let key = b.keys.recordKey(type: .tag, entityID: "work")
        let name = b.keys.recordBlobName(recordKey: key, hash: "abc")
        let blob = try SyncCrypto.sealBlob(Data("x".utf8), vaultID: SyncDevice.vaultID, name: name, keys: b.keys)
        try await server.putBlob(name: name, data: futureMagic("TRSC", from: blob))
        _ = await server.inject(recordKey: key, payload: SyncCrypto.pointer(toBlob: name))

        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(status.updateRequired)
        #expect(status.blockedThoughts == 0)
        #expect(try await b.state.parkedPointerCount() == 0)
        #expect(try await b.state.parkedCount() == 1)
        let gets = await server.blobGets
        await b.sync()
        #expect(await server.blobGets == gets, "it waits for an update instead of being fetched every cycle")
    }

    @Test func aPointerToABlobHoldingAFutureRecordFrameIsParked() async throws {
        let b = try await SyncDevice("B", server: server)
        let key = b.keys.recordKey(type: .tag, entityID: "work")
        let plain = Data(#"{"data":{},"deleted":false,"type":"settings","v":1}"#.utf8)
        let inner = futureMagic("TRS2", from: try SyncCrypto.seal(plain, vaultID: SyncDevice.vaultID, recordKey: key, payloadVersion: 1, keys: b.keys))
        let name = b.keys.recordBlobName(recordKey: key, hash: "abc")
        try await server.putBlob(name: name, data: try SyncCrypto.sealBlob(inner, vaultID: SyncDevice.vaultID, name: name, keys: b.keys))
        _ = await server.inject(recordKey: key, payload: SyncCrypto.pointer(toBlob: name))

        let status = await b.sync()
        #expect(status.lastError == nil && status.updateRequired && status.blockedThoughts == 0)
        #expect(try await b.state.parked(limit: 5).first?.payload == inner)
    }

    @Test func aPointerRepointedAtAnotherRecordsBlobIsHeldAndBacksOffWithoutWedging() async throws {
        let (a, b) = try await pair()
        let victim = a.store.create(body: String(repeating: "word ", count: 20_000), now: a.now(at(0)))
        let other = a.store.create(body: String(repeating: "else ", count: 20_000), now: a.now(at(1)))
        await a.sync()
        let victimKey = a.keys.recordKey(type: .thoughtContent, entityID: victim.id.uuidString)
        let otherKey = a.keys.recordKey(type: .thoughtContent, entityID: other.id.uuidString)
        let otherPointer = try #require(await server.rows[otherKey]).payload
        #expect(SyncCrypto.blobName(inPointer: otherPointer) != nil)
        _ = await server.inject(recordKey: victimKey, payload: otherPointer)
        let small = a.store.create(body: "small", now: a.now(at(2)))
        await a.sync()

        let status = await b.sync()
        #expect(status.lastError == nil && status.attention == nil, "an authentication failure behind a pointer doesn't stop sync")
        #expect(status.blockedThoughts == 1)
        #expect(try b.thought(victim.id) == nil)
        #expect(try b.thought(other.id) != nil)
        #expect(try b.thought(small.id) != nil)
        let gets = await server.blobGets
        await b.sync()
        #expect(await server.blobGets == gets, "backed off, not downloaded again next cycle")
    }

    // MARK: Pull cursor

    @Test func aPushLandingBetweenTheQueryAndTheHeadReadIsNotSkipped() async throws {
        let (a, b) = try await pair()
        a.store.create(body: "first", now: a.now(at(0)))
        await a.sync()
        let late = a.store.create(body: "lands mid-pull", now: a.now(at(1)))
        await server.afterNextPullQuery { [a] in await a.sync() }
        let first = await b.sync()
        #expect(first.lastError == nil)
        let cursor = try await b.state.cursor()
        #expect(cursor < (await server.headSeq), "the cursor is where the page ended, not at the head")
        #expect(first.headSeq == cursor)
        #expect(try b.thought(late.id) == nil)

        await b.sync()
        #expect(try b.thought(late.id) != nil, "the next pull brings what landed in between")
        try expectSame(a, b)
    }

    @Test(.timeLimit(.minutes(1))) func aServerThatHasMoreWithoutProgressStopsThePull() async throws {
        let b = try await SyncDevice("B", server: server)
        await server.stallPulls()
        let status = await b.sync()
        #expect(status.lastError?.contains("none after seq") == true)
        #expect(await server.pullCalls == 1)
    }

    // MARK: Head check

    @Test func anInterruptedPullIsResumedByTheHeadCheck() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server, config: .paged(pull: 2))
        for index in 0..<5 { a.store.create(body: "thought \(index)", now: a.now(at(Double(index)))) }
        await a.sync()
        await server.failNextCall(after: 2)
        let interrupted = await b.sync()
        #expect(interrupted.lastError != nil)
        #expect(interrupted.headSeq == nil, "not caught up, so the head isn't recorded as pulled")
        let partial = try b.thoughts().count
        #expect(partial > 0 && partial < 5)

        #expect(await b.engine.syncIfHeadMoved())
        #expect(try b.thoughts().count == 5)
        let status = await b.engine.status
        let head = await server.headSeq
        #expect(status.lastError == nil && status.headSeq == head)
    }

    @Test func aFailedCycleIsRetriedByTheHeadCheckEvenWhenNothingMoved() async throws {
        let (a, b) = try await pair()
        a.store.create(body: "one", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        #expect(await b.engine.status.headSeq == (await server.headSeq))
        await server.failNextCall()
        #expect(await b.sync().lastError != nil)
        let calls = await server.pullCalls
        #expect(await b.engine.syncIfHeadMoved(), "the head didn't move and nothing is queued, but the last cycle failed")
        #expect(await b.engine.status.lastError == nil)
        #expect(await server.pullCalls > calls)
        #expect(await b.engine.syncIfHeadMoved() == false)
    }

    @Test func theHeadCheckIgnoresEntriesThatCannotBePushed() async throws {
        var config = SyncEngine.Configuration()
        config.maxRecordBytes = 100_000
        let a = try await SyncDevice("A", server: server, config: config)
        a.store.create(body: String(repeating: "word ", count: 80_000), now: a.now(at(0)))
        a.store.create(body: "small", now: a.now(at(1)))
        let status = await a.sync()
        #expect(status.oversizedThoughts == 1 && status.pending == 1)
        _ = await a.engine.syncIfHeadMoved()

        let pulls = await server.pullCalls
        let pushes = await server.pushCalls
        let heads = await server.headCalls
        #expect(await a.engine.syncIfHeadMoved() == false, "the only thing queued can't be pushed, so no cycle")
        #expect(await server.headCalls == heads + 1)
        #expect(await server.pullCalls == pulls)
        #expect(await server.pushCalls == pushes)
    }

    // MARK: Push epoch

    @Test func aPushRejectedForAChangedEpochStopsAndNothingComesBack() async throws {
        let (a, b) = try await pair()
        a.store.create(body: "one", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        let created = b.store.create(body: "after the erase", now: b.now(at(5)))
        await server.beforeNextPush { [server] in await server.erase() }

        let status = await b.sync()
        #expect(status.attention == .epochChanged(known: 1, server: 2))
        #expect(status.phase == .stopped)
        #expect(await server.epochRejections == 1)
        #expect(await server.rows.isEmpty, "the erased vault stays erased")
        #expect(await server.blobs.isEmpty)
        let pushes = await server.pushCalls
        #expect(try await b.state.outboxCount() == 1, "the change stays queued, for the user to decide")

        let again = await b.sync()
        #expect(again.attention != nil)
        #expect(await server.pushCalls == pushes, "nothing is sent while it waits")
        #expect(await server.rows.isEmpty)
        #expect(try b.thought(created.id) != nil)
    }

    @Test(arguments: [false, true]) func aBlobUploadForAChangedEpochIsRefusedAndTheErasedVaultStaysEmpty(bigBody: Bool) async throws {
        let (a, b) = try await pair()
        a.store.create(body: "one", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        if bigBody {
            b.store.create(body: String(repeating: "word ", count: 20_000), now: b.now(at(5)))
        } else {
            let image = newImage(3)
            b.store.create(body: "pic " + ImageToken.token(for: image.id), images: [image], now: b.now(at(5)))
        }
        // The vault is erased after B's pull and before B uploads anything.
        b.makeEngine { inner in BeforeSnapshotsLocal(inner) { [server] in await server.erase() } }

        let status = await b.sync()
        #expect(status.attention == .epochChanged(known: 1, server: 2))
        #expect(await server.epochRejections >= 1)
        #expect(await server.rows.isEmpty)
        #expect(await server.blobs.isEmpty, "no orphan blobs in the erased vault")
        #expect(await server.blobPuts.isEmpty)
    }

    @Test func aPushCarriesTheEpochTheDeviceLastSaw() async throws {
        let (a, _) = try await pair()
        a.store.create(body: "one", now: a.now(at(0)))
        #expect(await a.sync().lastError == nil)
        #expect(await server.epochRejections == 0)
        #expect(await server.liveRecordCount == 3)
    }

    // MARK: Missing attachments

    @Test func aThoughtWhoseAttachmentBytesAreMissingIsHeldAndTheRestGoesOut() async throws {
        let (a, b) = try await pair()
        let image = newImage(7)
        let broken = a.store.create(body: "pic " + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        let plain = a.store.create(body: "plain", now: a.now(at(1)))
        let asset = try #require(broken.images?.first)
        let bytes = try #require(asset.data)
        asset.data = nil
        try a.context.save()

        let status = await a.sync()
        #expect(status.lastError == nil)
        #expect(status.missingAttachments == 1)
        #expect(status.pending == 1)
        let ids = await server.liveThoughtIDs(keys: a.keys, vaultID: SyncDevice.vaultID)
        #expect(ids == [plain.id], "the held thought isn't pushed without its attachment, and nothing else is dropped")
        #expect(await server.blobPuts.isEmpty)

        let again = await a.sync()
        #expect(again.missingAttachments == 1, "retried every cycle")

        asset.data = bytes
        try a.context.save()
        let recovered = await a.sync()
        #expect(recovered.lastError == nil && recovered.missingAttachments == 0 && recovered.pending == 0)
        await b.sync()
        let copy = try #require(try b.thought(broken.id))
        #expect(copy.images?.count == 1)
        try expectSame(a, b)
    }

    // MARK: Parked records

    @Test func parkedRecordsAreTriedAgainUntilEveryReadableOneApplied() async throws {
        let (a, b) = try await pair()
        let source = a.store.create(body: "from the future", now: a.now(at(0)))
        for payload in [SyncPayload.thoughtContent(ThoughtContentRecord(source)), .thoughtMeta(ThoughtMetaRecord(source))] {
            let key = a.keys.recordKey(type: payload.type, entityID: source.id.uuidString)
            var text = String(decoding: try payload.encoded(), as: UTF8.self)
            text.removeLast(6)
            let frame = try SyncCrypto.seal(Data((text + "\"v\":2}").utf8), vaultID: SyncDevice.vaultID, recordKey: key, payloadVersion: 2, keys: b.keys)
            _ = await server.inject(recordKey: key, payload: frame)
        }
        #expect(await b.sync().updateRequired)

        var upgraded = SyncEngine.Configuration()
        upgraded.payloadVersion = 2
        upgraded.readerVersion = 2
        b.makeEngine(config: upgraded)
        b.failSaves = 1
        await b.sync()
        b.failSaves = 0
        #expect(try await b.state.parkedVersionTried() != 2, "an apply failed, so the parked records must be tried again")
        #expect(try b.thought(source.id) == nil)

        let status = await b.sync()
        #expect(status.lastError == nil && !status.updateRequired)
        #expect(try await b.state.parkedVersionTried() == 2)
        #expect(try b.thought(source.id)?.body == "from the future")
        #expect(try await b.state.parkedCount() == 0)
        try await b.expectClean()
    }

    @Test func aRecordParkedForAKeyGenerationIsAppliedWhenTheReaderVersionIsBumped() async throws {
        let b = try await SyncDevice("B", server: server)
        let tag = SyncPayload.tag(TagRecord(name: "rotated", displayName: "Rotated", colorHex: nil, updatedAt: nil))
        let key = b.keys.recordKey(type: .tag, entityID: "rotated")
        let frame = try SyncCrypto.seal(
            try tag.encoded(), vaultID: SyncDevice.vaultID, recordKey: key, payloadVersion: 1, keys: b.keys, keyGeneration: 2
        )
        _ = await server.inject(recordKey: key, payload: frame)
        #expect(await b.sync().updateRequired)
        #expect(try await b.state.parkedCount() == 1)

        var sameVersion = SyncEngine.Configuration()
        sameVersion.readerVersion = 2
        sameVersion.keyGeneration = 2
        #expect(sameVersion.payloadVersion == SyncPayload.currentVersion)
        b.makeEngine(config: sameVersion)
        let status = await b.sync()
        #expect(status.lastError == nil && !status.updateRequired)
        #expect(try await b.state.parkedCount() == 0)
        #expect(try b.context.fetch(FetchDescriptor<ThoughtReps.Tag>()).contains { $0.name == "rotated" })
    }

    @Test func theHeadCheckSkipsAnOutboxOfOnlyMissingAttachments() async throws {
        let a = try await SyncDevice("A", server: server)
        let image = newImage(9)
        let broken = a.store.create(body: "pic " + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        try #require(broken.images?.first).data = nil
        try a.context.save()
        let status = await a.sync()
        #expect(status.missingAttachments == 1)
        _ = await a.engine.syncIfHeadMoved()

        let pulls = await server.pullCalls
        #expect(await a.engine.syncIfHeadMoved() == false)
        #expect(await server.pullCalls == pulls)
    }

    @Test func manyParkedRecordsAreAppliedPageByPage() async throws {
        let b = try await SyncDevice("B", server: server)
        for index in 0..<30 {
            let name = "tag\(index)"
            let payload = SyncPayload.tag(TagRecord(name: name, displayName: name, colorHex: nil, updatedAt: nil))
            var text = String(decoding: try payload.encoded(), as: UTF8.self)
            text.removeLast(6)
            let key = b.keys.recordKey(type: .tag, entityID: name)
            _ = await server.inject(
                recordKey: key,
                payload: try SyncCrypto.seal(Data((text + "\"v\":2}").utf8), vaultID: SyncDevice.vaultID, recordKey: key, payloadVersion: 2, keys: b.keys)
            )
        }
        await b.sync()
        #expect(try await b.state.parkedCount() == 30)
        let firstPage = try await b.state.parked(limit: 8)
        let secondPage = try await b.state.parked(after: (firstPage[7].seq, firstPage[7].recordKey), limit: 8)
        #expect(firstPage.count == 8 && secondPage.count == 8)
        #expect(Set(firstPage.map(\.recordKey)).isDisjoint(with: secondPage.map(\.recordKey)))

        var upgraded = SyncEngine.Configuration()
        upgraded.payloadVersion = 2
        upgraded.readerVersion = 2
        b.makeEngine(config: upgraded)
        let status = await b.sync()
        #expect(status.lastError == nil && !status.updateRequired)
        #expect(try await b.state.parkedCount() == 0)
        #expect(try b.context.fetch(FetchDescriptor<ThoughtReps.Tag>()).count == 30)
    }

    // MARK: Blob downloads

    @Test func aPointerBlobOverTheDownloadCapHoldsOnlyThatThought() async throws {
        var capped = SyncEngine.Configuration()
        capped.maxRecordBytes = 100_000
        let (a, b) = try await pair(configB: capped)
        let big = a.store.create(body: String(repeating: "word ", count: 80_000), now: a.now(at(0)))
        let small = a.store.create(body: "small", now: a.now(at(1)))
        await a.sync()

        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(status.blockedThoughts == 1)
        #expect(try b.thought(big.id) == nil)
        #expect(try b.thought(small.id) != nil)
    }

    // MARK: Local writes during a push

    @Test func aLocalWriteDuringThePushStaysQueuedAndIsPushedNext() async throws {
        let (a, b) = try await pair()
        let thought = a.store.create(body: "v1", now: a.now(at(0)))
        let id = thought.id
        let writtenAt = a.now(at(5))
        await server.beforeNextPush { [a] in
            await MainActor.run {
                if let current = try? a.thought(id) {
                    a.store.update(current, body: "v2 written during the push", blocks: [], intervalDays: nil, now: writtenAt)
                }
            }
        }
        let first = await a.sync()
        #expect(first.lastError == nil)
        #expect(first.pending == 1, "the push confirmed v1, but the entry for v2 stays")
        let second = await a.sync()
        #expect(second.pending == 0)
        await b.sync()
        #expect(try b.thought(id)?.body == "v2 written during the push")
        try expectSame(a, b)
        try await b.expectClean()
    }

    // MARK: Rebuilt state

    @Test func aFreshStartQueuesWhatSyncStateDoesNotKnow() async throws {
        let a = try await SyncDevice("A", server: server)
        let thought = a.store.create(body: "written before", now: a.now(at(0)))
        try await a.state.resetSyncProgress()
        #expect(try await a.state.outboxCount() == 0, "the outbox was lost with the file")

        var counting: ReconcileCountingLocal?
        a.makeEngine { inner in
            let wrapped = ReconcileCountingLocal(inner)
            counting = wrapped
            return wrapped
        }
        #expect(await a.sync().lastError == nil)
        #expect(try #require(counting).reconciles == 1)
        #expect(try await a.state.record(forKey: a.keys.recordKey(type: .thoughtContent, entityID: thought.id.uuidString)) != nil)
        #expect(await server.liveThoughtIDs(keys: a.keys, vaultID: SyncDevice.vaultID) == [thought.id], "it was pushed, which nothing else would have queued")

        await a.sync()
        let caughtUp = try #require(counting).reconciles
        #expect(await a.engine.status.cursor == (await server.headSeq))
        await a.sync()
        #expect(try #require(counting).reconciles == caughtUp, "once the cursor has moved, a pull no longer starts from scratch")
    }
}
