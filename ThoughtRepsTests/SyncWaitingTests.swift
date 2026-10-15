import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync waiting on the server's version")
struct SyncWaitingTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func key(_ type: SyncRecordType, _ id: UUID, _ device: SyncDevice) -> String {
        device.keys.recordKey(type: type, entityID: id.uuidString)
    }

    func futureVersion(_ payload: SyncPayload) throws -> Data {
        var text = String(decoding: try payload.encoded(), as: UTF8.self)
        text.removeLast(6)
        return Data((text + "\"v\":2}").utf8)
    }

    /// Puts the thought's records on the server as a newer version of the app would have written them.
    func injectFuture(of thought: Thought, as device: SyncDevice) async throws {
        for payload in [SyncPayload.thoughtContent(ThoughtContentRecord(thought)), .thoughtMeta(ThoughtMetaRecord(thought))] {
            let recordKey = key(payload.type, thought.id, device)
            _ = await server.inject(
                recordKey: recordKey,
                payload: try SyncCrypto.seal(try futureVersion(payload), vaultID: SyncDevice.vaultID, recordKey: recordKey, payloadVersion: 2, keys: device.keys)
            )
        }
    }

    /// B is behind and the server has forgotten the tombstones between: B's next pull is a full resync.
    func makeBBehind(_ a: SyncDevice) async throws {
        a.store.create(body: "filler", now: a.now(at(50)))
        await a.sync()
        await server.prune(tombstonesBelow: await server.headSeq + 1)
    }

    // MARK: Resync leaves what it couldn't apply alone

    @Test func aResyncDoesNotDeleteAParkedThought() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let thought = a.store.create(body: "tracked", now: a.now(at(0)))
        let id = thought.id
        await a.sync()
        await b.sync()
        a.store.update(thought, body: "edited by a newer app", blocks: [], intervalDays: nil, now: a.now(at(10)))
        try await injectFuture(of: thought, as: b)
        let contentKey = key(.thoughtContent, id, b)
        let seq = await server.rows[contentKey]?.seq
        try await makeBBehind(a)

        let status = await b.sync()
        #expect(status.lastError == nil && status.updateRequired)
        #expect(try b.thought(id) != nil)
        #expect(try b.tombstones().isEmpty)
        let row = await server.rows[contentKey]
        #expect(row?.seq == seq && row?.deleted == false, "no deletion was pushed")
        #expect(try await b.state.hasResyncSnapshot(), "still unresolved")
    }

    @Test func aResyncDoesNotDeleteABlockedThought() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let thought = a.store.create(body: "tracked", now: a.now(at(0)))
        let id = thought.id
        await a.sync()
        await b.sync()
        let image = newImage(8)
        a.store.update(thought, body: "now with " + ImageToken.token(for: image.id), blocks: [], images: [image], intervalDays: nil, now: a.now(at(10)))
        await a.sync()
        _ = await server.removeAllBlobs()
        try await makeBBehind(a)

        let status = await b.sync()
        #expect(status.lastError == nil && status.blockedThoughts == 1)
        #expect(try b.thought(id) != nil)
        #expect(try b.tombstones().isEmpty)
        #expect(await server.liveThoughtIDs(keys: a.keys, vaultID: SyncDevice.vaultID).contains(id))
        #expect(try await b.state.hasResyncSnapshot())
    }

    @Test func aResyncDoesNotDeleteAHeldThought() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let id = a.store.create(body: "tracked", now: a.now(at(0))).id
        await a.sync()
        await b.sync()
        try await b.state.resetSyncProgress(keepingEpoch: true, snapshotting: true)
        let held = HeldRecord(recordKey: key(.thoughtMeta, id, b), type: .thoughtMeta, entityID: id.uuidString, seq: 2, payload: Data("{}".utf8))
        try await b.state.commit(PageCommit(hold: [held], cursor: 0, epoch: 1))
        await server.forget(recordKeys: [key(.thoughtContent, id, b), key(.thoughtMeta, id, b)])

        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(try b.thought(id) != nil)
        #expect(try b.tombstones().isEmpty)
        #expect(try await b.state.hasResyncSnapshot())
    }

    // MARK: Local edits wait for the server's version

    @Test func aLocalEditToAParkedThoughtStaysQueuedUntilTheUpdateThenMerges() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let thought = a.store.create(body: "shared", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        a.store.update(thought, body: "A edit", blocks: [], intervalDays: nil, now: a.now(at(100)))
        try await injectFuture(of: thought, as: b)
        let metaKey = key(.thoughtMeta, thought.id, b)
        let seq = await server.rows[metaKey]?.seq

        let copy = try #require(try b.thought(thought.id))
        b.store.setPinned(copy, true, now: b.now(at(200)))
        let other = b.store.create(body: "unrelated", now: b.now(at(201)))
        let waiting = await b.sync()
        #expect(waiting.lastError == nil)
        #expect(waiting.updateRequired && waiting.waitingThoughts == 1 && waiting.pending == 1)
        #expect(await server.rows[metaKey]?.seq == seq, "the server's version wasn't overwritten")
        #expect(await server.recordPushes[key(.thoughtContent, other.id, b)] == 1, "the rest of the batch went out")

        var upgraded = SyncEngine.Configuration()
        upgraded.payloadVersion = 2
        b.makeEngine(config: upgraded)
        let merged = await b.sync()
        #expect(merged.lastError == nil && merged.pending == 0 && merged.waitingThoughts == 0)
        #expect(copy.body == "A edit" && copy.isPinned)
        await a.sync()
        #expect(try #require(try a.thought(thought.id)).isPinned)
    }

    @Test func aLocalEditToABlockedThoughtStaysQueuedUntilTheBlobReturns() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let thought = a.store.create(body: "shared", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        let image = newImage(9)
        a.store.update(thought, body: "with " + ImageToken.token(for: image.id), blocks: [], images: [image], intervalDays: nil, now: a.now(at(10)))
        await a.sync()
        let saved = await server.removeAllBlobs()
        let metaKey = key(.thoughtMeta, thought.id, b)
        let seq = await server.rows[metaKey]?.seq

        let copy = try #require(try b.thought(thought.id))
        b.store.setPinned(copy, true, now: b.now(at(20)))
        let waiting = await b.sync()
        #expect(waiting.lastError == nil)
        #expect(waiting.blockedThoughts == 1 && waiting.waitingThoughts == 1 && waiting.pending == 1)
        #expect(await server.rows[metaKey]?.seq == seq)

        await server.restoreBlobs(saved)
        let done = await b.sync()
        #expect(done.lastError == nil && done.pending == 0 && done.waitingThoughts == 0 && done.blockedThoughts == 0)
        #expect(copy.isPinned && (copy.images ?? []).count == 1)
        await a.sync()
        #expect(try #require(try a.thought(thought.id)).isPinned)
        #expect(try a.canonicalDump() == b.canonicalDump())
        try await b.expectClean()
    }
}
