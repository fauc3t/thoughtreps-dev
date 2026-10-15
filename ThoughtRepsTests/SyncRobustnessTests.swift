import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync robustness")
struct SyncRobustnessTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func pair(configB: SyncEngine.Configuration = .init()) async throws -> (SyncDevice, SyncDevice) {
        (try await SyncDevice("A", server: server), try await SyncDevice("B", server: server, config: configB))
    }

    func expectSame(_ a: SyncDevice, _ b: SyncDevice, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(try a.canonicalDump() == b.canonicalDump(), sourceLocation: sourceLocation)
    }

    // MARK: Monotonic skew clock

    @Test func aLaggingDevicesSequentialEditsToOneGroupKeepTheLastOne() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server, clockOffset: -5 * 3600)
        let thought = a.store.create(body: "start", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        a.store.update(thought, body: "A", blocks: [], intervalDays: nil, now: a.now(at(100)))
        await a.sync()
        await b.sync()

        let copy = try #require(try b.thought(thought.id))
        b.store.setPinned(copy, true, now: b.now(at(200)))
        b.store.setPinned(copy, false, now: b.now(at(201)))
        b.store.snooze(copy, days: 3, now: b.now(at(202)))
        b.store.snooze(copy, days: 10, now: b.now(at(203)))
        b.store.update(copy, body: "B1", blocks: [], intervalDays: nil, now: b.now(at(204)))
        b.store.update(copy, body: "B2", blocks: [], intervalDays: nil, now: b.now(at(205)))
        #expect(copy.stateChangedAt > a.now(at(100)), "stamped past the peer's clock")
        await b.sync()
        await a.sync()
        let onA = try #require(try a.thought(thought.id))
        #expect(!onA.isPinned)
        #expect(onA.body == "B2")
        #expect(onA.nextDueAt == copy.nextDueAt)
        try expectSame(a, b)
    }

    @Test func aPeerWithAWildClockIsAppliedButCannotPullStampsPastTomorrow() async throws {
        let a = try await SyncDevice("A", server: server, clockOffset: 2_000_000_000)
        let b = try await SyncDevice("B", server: server)
        let thought = a.store.create(body: "from the future", now: a.now(at(0)))
        #expect(thought.updatedAt > Date.now.addingTimeInterval(365 * 86_400))
        await a.sync()
        await b.sync()
        let copy = try #require(try b.thought(thought.id))
        #expect(copy.updatedAt == thought.updatedAt, "the record keeps its real clock")
        let ceiling = Date.now.addingTimeInterval(86_400 + 1)
        #expect(SyncClock(defaults: b.defaults).highestSeen <= ceiling)
        let mine = b.store.create(body: "mine", now: b.now(at(5)))
        #expect(mine.updatedAt <= ceiling)
        b.store.setPinned(mine, true, now: b.now(at(6)))
        b.store.setPinned(mine, false, now: b.now(at(7)))
        #expect(mine.stateChangedAt <= ceiling)
    }

    // MARK: Bounded apply

    @Test(arguments: [5, 1])
    func aPageWhoseBlobsExceedTheCapIsAppliedInSubBatches(cap: Int) async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        for index in 0..<4 {
            let image = newImage(UInt8(index + 1))
            a.store.create(body: "pic \(index) " + ImageToken.token(for: image.id), images: [image], now: a.now(at(Double(index))))
        }
        a.store.create(body: "no image", now: a.now(at(10)))
        await a.sync()
        var config = SyncEngine.Configuration()
        config.maxApplyBytes = cap
        var counter: CountingLocal?
        b.makeEngine(config: config) { inner in
            let counting = CountingLocal(inner)
            counter = counting
            return counting
        }
        let status = await b.sync()
        #expect(status.lastError == nil)
        let applies = try #require(counter).applies
        #expect(applies.filter { $0 > 0 }.count >= 4, "each 3-byte thought alone or nearly: \(applies)")
        #expect(applies.allSatisfy { $0 <= 2 })
        #expect(try b.thoughts().count == 5)
        try expectSame(a, b)
        try await b.expectClean()
    }

    @Test func withTheDefaultCapASmallPageIsOneBatch() async throws {
        let (a, b) = try await pair()
        for index in 0..<3 {
            let image = newImage(UInt8(index + 1))
            a.store.create(body: "pic " + ImageToken.token(for: image.id), images: [image], now: a.now(at(Double(index))))
        }
        await a.sync()
        var counter: CountingLocal?
        b.makeEngine { inner in
            let counting = CountingLocal(inner)
            counter = counting
            return counting
        }
        await b.sync()
        #expect(try #require(counter).applies == [3])
    }

    // MARK: Records this version can't read

    func key(_ type: SyncRecordType, _ id: UUID, _ device: SyncDevice) -> String {
        device.keys.recordKey(type: type, entityID: id.uuidString)
    }

    /// The payload as a newer version of the app would have written it: the same shape, version 2.
    func futureVersion(_ payload: SyncPayload) throws -> Data {
        var text = String(decoding: try payload.encoded(), as: UTF8.self)
        #expect(text.hasSuffix("\"v\":1}"))
        text.removeLast(6)
        return Data((text + "\"v\":2}").utf8)
    }

    @Test func recordsFromANewerVersionAreParkedAndSyncingGoesOn() async throws {
        let (a, b) = try await pair()
        let unknownKey = "future-record-key"
        let unknown = Data(#"{"data":{},"deleted":false,"type":"future.thing","v":1}"#.utf8)
        _ = await server.inject(recordKey: unknownKey, payload: try SyncCrypto.seal(unknown, vaultID: SyncDevice.vaultID, recordKey: unknownKey, payloadVersion: 1, keys: b.keys))
        let newer = Data(#"{"data":{},"deleted":false,"type":"settings","v":2}"#.utf8)
        _ = await server.inject(recordKey: "newer-key", payload: try SyncCrypto.seal(newer, vaultID: SyncDevice.vaultID, recordKey: "newer-key", payloadVersion: 2, keys: b.keys))
        let thought = a.store.create(body: "ordinary", now: a.now(at(0)))
        await a.sync()
        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(status.updateRequired)
        #expect(try await b.state.parkedCount() == 2)
        #expect(try await b.state.cursor() == (await server.headSeq), "the cursor moved past them")
        #expect(try b.thought(thought.id) != nil)
    }

    @Test func parkedRecordsAreAppliedAfterTheAppIsUpdated() async throws {
        let (a, b) = try await pair()
        let source = a.store.create(body: "from the future", now: a.now(at(0)))
        let content = SyncPayload.thoughtContent(ThoughtContentRecord(source))
        let meta = SyncPayload.thoughtMeta(ThoughtMetaRecord(source))
        for payload in [content, meta] {
            let recordKey = key(payload.type, source.id, b)
            _ = await server.inject(
                recordKey: recordKey,
                payload: try SyncCrypto.seal(try futureVersion(payload), vaultID: SyncDevice.vaultID, recordKey: recordKey, payloadVersion: 2, keys: b.keys)
            )
        }
        let parked = await b.sync()
        #expect(parked.updateRequired)
        #expect(try b.thought(source.id) == nil)

        var upgraded = SyncEngine.Configuration()
        upgraded.payloadVersion = 2
        upgraded.readerVersion = 2
        b.makeEngine(config: upgraded)
        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(!status.updateRequired)
        #expect(try await b.state.parkedCount() == 0)
        #expect(try #require(try b.thought(source.id)).body == "from the future")
        try await b.expectClean()
    }

    @Test func aRecordThatFailsToDecryptStopsTheCycleAndKeepsTheCursor() async throws {
        let (a, b) = try await pair()
        a.store.create(body: "first", now: a.now(at(0)))
        await a.sync()
        let tamperedKey = "tampered-key"
        let plain = Data(#"{"data":{},"deleted":false,"type":"settings","v":1}"#.utf8)
        _ = await server.inject(
            recordKey: tamperedKey,
            payload: try SyncCrypto.seal(plain, vaultID: "someone-else", recordKey: tamperedKey, payloadVersion: 1, keys: b.keys)
        )
        let status = await b.sync()
        #expect(status.lastError != nil)
        #expect(try await b.state.cursor() == 0)
        #expect(try await b.state.parkedCount() == 0)
    }

    // MARK: Blobs that can't be had

    @Test func aMissingBlobHoldsOnlyThatThoughtUntilTheBlobIsBack() async throws {
        let (a, b) = try await pair()
        let image = newImage(4)
        let withImage = a.store.create(body: "pic " + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        let plain = a.store.create(body: "plain", now: a.now(at(1)))
        await a.sync()
        let saved = await server.removeAllBlobs()
        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(status.blockedThoughts == 1)
        #expect(try b.thought(plain.id) != nil, "everything else carries on")
        #expect(try b.thought(withImage.id) == nil)
        #expect(try await b.state.heldCount() == 2)
        #expect(try await b.state.record(forKey: key(.thoughtContent, withImage.id, b)) == nil, "no base while it's held")

        let still = await b.sync()
        #expect(still.blockedThoughts == 1, "retried every cycle, still blocked")
        await server.restoreBlobs(saved)
        let recovered = await b.sync()
        #expect(recovered.lastError == nil && recovered.blockedThoughts == 0)
        #expect(try b.thought(withImage.id) != nil)
        #expect(try await b.state.heldCount() == 0)
        #expect(try await b.state.record(forKey: key(.thoughtContent, withImage.id, b)) != nil)
        try expectSame(a, b)
        try await b.expectClean()
    }

    @Test func aRejectedThoughtIsTriedAgainOnEveryCycle() async throws {
        let (a, b) = try await pair()
        let shared = UUID()
        let theirs = a.store.create(
            body: "theirs " + ImageToken.token(for: shared), images: [ImageDraft(id: shared, processed: fakeImage(1))], now: a.now(at(0))
        )
        let mine = b.store.create(
            body: "mine " + ImageToken.token(for: shared), images: [ImageDraft(id: shared, processed: fakeImage(1))], now: b.now(at(1))
        )
        await a.sync()
        await b.sync()
        #expect(try b.thought(theirs.id) == nil)
        #expect(try await b.state.blockedEntityIDs() == [theirs.id.uuidString])
        // Once the other thought lets go of the image, nothing new has to arrive for the held one to come in.
        b.store.delete(mine, now: b.now(at(5)))
        await b.sync()
        #expect(try b.thought(theirs.id) != nil)
        #expect(try await b.state.blockedEntityIDs().isEmpty)
        try await b.expectClean()
    }

    // MARK: 410 and deletions

    @Test func aFullResyncDeletesWhatWasDeletedElsewhereUnlessItWasEditedHere() async throws {
        let (a, b) = try await pair()
        let plain = a.store.create(body: "plain", now: a.now(at(0)))
        let edited = a.store.create(body: "edited", now: a.now(at(0)))
        let keep = a.store.create(body: "keep", now: a.now(at(0)))
        let plainID = plain.id
        let editedID = edited.id
        let keepID = keep.id
        await a.sync()
        await b.sync()
        a.store.delete(plain, now: a.now(at(100)))
        a.store.delete(edited, now: a.now(at(100)))
        await a.sync()
        await server.prune(tombstonesBelow: await server.headSeq + 1)

        // B was away. A view isn't an edit; a content change is; a thought B never synced just goes up.
        b.store.markViewed(try #require(try b.thought(plainID)), now: b.now(at(200)))
        b.store.update(try #require(try b.thought(editedID)), body: "edited on B", blocks: [], intervalDays: nil, now: b.now(at(201)))
        let fresh = b.store.create(body: "new on B", now: b.now(at(202)))
        let freshID = fresh.id

        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(try b.thought(plainID) == nil, "deleted elsewhere and only viewed here")
        #expect(try b.tombstones().contains { $0.id == plainID })
        #expect(try b.thought(editedID) != nil, "edited here since its last sync")
        try await syncToQuiescence([a, b], server: server)
        for device in [a, b] {
            #expect(try device.thought(plainID) == nil)
            #expect(try device.thought(keepID) != nil)
            #expect(try device.thought(freshID) != nil)
            #expect(try device.thought(editedID)?.body == "edited on B")
            try await device.expectClean()
        }
        try expectSame(a, b)
    }

    @Test func anUnreadableBlobIsRetriedWithBackoffNotEveryCycle() async throws {
        let (a, b) = try await pair()
        let image = newImage(4)
        let thought = a.store.create(body: "pic " + ImageToken.token(for: image.id), images: [image], now: a.now(at(0)))
        await a.sync()
        let good = await server.removeAllBlobs()
        for name in good.keys { try await server.putBlob(name: name, data: Data("junk, not a sealed blob".utf8)) }
        for _ in 0..<12 { await b.sync() }
        let gets = await server.blobGets
        #expect(gets >= 2 && gets <= 5, "12 cycles tried the broken blob \(gets) times")
        #expect(try b.thought(thought.id) == nil)
        await server.restoreBlobs(good)
        var cycles = 0
        while try b.thought(thought.id) == nil, cycles < 40 {
            await b.sync()
            cycles += 1
        }
        #expect(try b.thought(thought.id) != nil, "retried eventually")
        try await b.expectClean()
    }

    @Test func aPoisonedHeldThoughtDoesNotStopTheCycle() async throws {
        let (a, b) = try await pair()
        await a.sync()
        await b.sync()
        let poisoned = UUID()
        let poison = HeldRecord(
            recordKey: key(.thoughtContent, poisoned, b), type: .thoughtContent, entityID: poisoned.uuidString, seq: 1,
            payload: Data("not json".utf8), blocked: true
        )
        try await b.state.commit(PageCommit(hold: [poison], cursor: try await b.state.cursor(), epoch: 1))
        let other = a.store.create(body: "carries on", now: a.now(at(0)))
        await a.sync()
        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(try b.thought(other.id) != nil)
        #expect(try await b.state.heldCount() == 1)
        b.store.create(body: "and pushes", now: b.now(at(5)))
        #expect((await b.sync()).pending == 0)
    }

    @Test func leavingSyncForgetsTheSkewClock() async throws {
        let (a, _) = try await pair()
        SyncClock(defaults: a.defaults).observe(at(5_000))
        a.store.create(body: "one", now: a.now(at(0)))
        #expect(SyncClock(defaults: a.defaults).highestSeen != .distantPast)
        a.store.deleteAll()
        #expect(SyncClock(defaults: a.defaults).highestSeen == .distantPast)
        let after = a.store.create(body: "two", now: at(1))
        #expect(after.updatedAt == at(1))
    }
}
