import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync parked records, resync and remote deletions")
struct SyncParkedAndResyncTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func injectFutureTag(_ name: String, via device: SyncDevice) async throws {
        let payload = SyncPayload.tag(TagRecord(name: name, displayName: name.capitalized, colorHex: nil, updatedAt: nil))
        var text = String(decoding: try payload.encoded(), as: UTF8.self)
        text.removeLast(6)
        let key = device.keys.recordKey(type: .tag, entityID: name)
        _ = await server.inject(
            recordKey: key,
            payload: try SyncCrypto.seal(Data((text + "\"v\":2}").utf8), vaultID: SyncDevice.vaultID, recordKey: key, payloadVersion: 2, keys: device.keys)
        )
    }

    @Test func aParkedTagRecordDoesNotBlockTheRestOfTheBatch() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        try await injectFutureTag("work", via: b)
        await b.sync()
        b.store.create(body: "hello #work", now: b.now(at(1)))
        let other = b.store.create(body: "plain", now: b.now(at(2)))
        let status = await b.sync()
        #expect(status.lastError == nil)
        await a.sync()
        #expect(try a.thought(other.id) != nil)
    }

    @Test func parkedRecordsAreTriedAgainOnlyWhenThePayloadVersionChanges() async throws {
        let b = try await SyncDevice("B", server: server)
        try await injectFutureTag("work", via: b)
        await b.sync()
        #expect(try await b.state.parkedCount() == 1)
        #expect(try await b.state.parkedVersionTried() == SyncPayload.currentVersion)
        let key = b.keys.recordKey(type: .tag, entityID: "work")
        #expect(try await b.state.parkedKeys(among: [key, "other"]) == [key])

        var newer = SyncEngine.Configuration()
        newer.payloadVersion = 2
        b.makeEngine(config: newer)
        await b.sync()
        #expect(try await b.state.parkedVersionTried() == 2)
    }

    @Test func aFromScratchPullInterruptedPartwayResumesAndFinishes() async throws {
        let a = try await SyncDevice("A", server: server)
        for i in 0..<20 { a.store.create(body: "t\(i)", now: a.now(at(Double(i)))) }
        await a.sync()
        await server.prune(tombstonesBelow: await server.headSeq + 1)
        let b = try await SyncDevice("B", server: server, config: .paged(pull: 2))
        var attempts = 0
        while try b.thoughts().count < 20, attempts < 40 {
            await server.failNextCall(after: 4)
            await b.sync()
            attempts += 1
        }
        #expect(try b.thoughts().count == 20)
        #expect(try await b.state.isResyncing() == false)
        await server.clearFailures()
        #expect(await b.sync().lastError == nil)
    }

    @Test func a410InsidePushResolvesTheResyncToo() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let shared = a.store.create(body: "shared", now: a.now(at(1)))
        let doomed = a.store.create(body: "doomed", now: a.now(at(2)))
        try await syncToQuiescence([a, b], server: server)
        #expect(try b.thought(doomed.id) != nil)

        a.store.delete(doomed, now: a.now(at(10)))
        await a.sync()
        b.store.update(try #require(try b.thought(shared.id)), body: "edited on B", blocks: [], intervalDays: nil, now: b.now(at(20)))
        let server = server
        let sharedID = shared.id
        await server.beforeNextPush { @Sendable in
            await MainActor.run { a.store.update(try! #require(try a.thought(sharedID)), body: "edited on A", blocks: [], intervalDays: nil, now: a.now(at(30))) }
            await a.sync()
            await server.prune(tombstonesBelow: await server.headSeq + 1)
        }
        await b.sync()
        try await syncToQuiescence([a, b], server: server)
        #expect(try b.thought(doomed.id) == nil)
        #expect(try a.thought(doomed.id) == nil)
        #expect(Set(try a.thoughts().map(\.id)) == Set(try b.thoughts().map(\.id)))
    }

    @Test func aRemoteDeletionRaisesAnExistingTombstoneAndNothingFlipsBack() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let thought = a.store.create(body: "both delete", now: a.now(at(1)))
        try await syncToQuiescence([a, b], server: server)
        a.store.delete(thought, now: a.now(at(10)))
        b.store.delete(try #require(try b.thought(thought.id)), now: b.now(at(20)))
        try await syncToQuiescence([a, b], server: server)

        let deletedA = try #require(try a.tombstones().first { $0.id == thought.id }).deletedAt
        let deletedB = try #require(try b.tombstones().first { $0.id == thought.id }).deletedAt
        #expect(deletedA == deletedB)
        #expect(deletedA == b.now(at(20)))
        for device in [a, b] {
            #expect(try await device.state.outboxCount() == 0)
            #expect(try await device.reconcile().deletions == 0)
        }
    }

    @Test func reconcileRunsAfterTheOneInProgressInsteadOfBeingSkipped() async throws {
        let a = try await SyncDevice("A", server: server)
        async let first = SyncReconcileRunner.reconcile(container: a.container, state: a.state)
        async let second = SyncReconcileRunner.reconcile(container: a.container, state: a.state)
        let results = await [first, second]
        #expect(results.allSatisfy { $0 != nil })
    }
}
