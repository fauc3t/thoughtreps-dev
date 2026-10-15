import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync large records")
struct SyncLargeRecordTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    static func bigBody(_ bytes: Int) -> String {
        String(repeating: "word ", count: bytes / 5)
    }

    @Test func aBigThoughtAndManySmallOnesAllReachAnotherDevice() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let big = a.store.create(body: Self.bigBody(2_500_000), now: a.now(at(1)))
        var small: [UUID] = []
        for i in 0..<120 { small.append(a.store.create(body: "small \(i)", now: a.now(at(2 + Double(i)))).id) }
        let status = await a.sync()
        #expect(status.lastError == nil)
        #expect(try await a.state.outboxCount() == 0)
        await b.sync()
        #expect(try b.thought(big.id)?.body.count == 2_500_000)
        #expect(try small.allSatisfy { try b.thought($0) != nil })
        let key = a.keys.recordKey(type: .thoughtContent, entityID: big.id.uuidString)
        let row = try #require(await server.rows[key])
        #expect(SyncCrypto.blobName(inPointer: row.payload) != nil)
        #expect(row.payload.count <= SyncLimits.maxInlinePayload)
        try await b.expectClean()
    }

    @Test func aDroppedPushResponseAfterTheBlobUploadRetriesSafely() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let big = a.store.create(body: Self.bigBody(300_000), now: a.now(at(1)))
        await server.dropNextPushResponse()
        #expect(await a.sync().lastError != nil)
        let events = await server.events
        let upload = try #require(events.firstIndex { if case .putBlob = $0 { true } else { false } })
        let push = try #require(events.firstIndex { if case .push = $0 { true } else { false } })
        #expect(upload < push)
        #expect(await a.sync().lastError == nil)
        #expect(await server.blobPuts.values.allSatisfy { $0 == 1 })
        #expect(try await a.state.outboxCount() == 0)
        await b.sync()
        #expect(try b.thought(big.id)?.body.count == 300_000)
    }

    @Test func aMissingPointerBlobHoldsOnlyThatThought() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let big = a.store.create(body: Self.bigBody(200_000), now: a.now(at(1)))
        let other = a.store.create(body: "small", now: a.now(at(2)))
        await a.sync()
        let saved = await server.removeAllBlobs()
        let status = await b.sync()
        #expect(status.lastError == nil)
        #expect(status.blockedThoughts == 1)
        #expect(try b.thought(big.id) == nil)
        #expect(try b.thought(other.id) != nil)

        b.store.create(body: "made on B", now: b.now(at(5)))
        #expect(await b.sync().lastError == nil)
        #expect(try b.thought(big.id) == nil)

        await server.restoreBlobs(saved)
        let after = await b.sync()
        #expect(after.blockedThoughts == 0)
        #expect(try b.thought(big.id)?.body.count == 200_000)
        #expect(try await b.state.parkedCount() == 0)
        try await syncToQuiescence([a, b], server: server)
        try await b.expectClean()
    }

    @Test func aThoughtOverTheRecordLimitIsHeldWithoutBlockingTheRest() async throws {
        var config = SyncEngine.Configuration()
        config.maxRecordBytes = 100_000
        let a = try await SyncDevice("A", server: server, config: config)
        let b = try await SyncDevice("B", server: server)
        let huge = a.store.create(body: Self.bigBody(400_000), now: a.now(at(1)))
        let other = a.store.create(body: "small", now: a.now(at(2)))
        let status = await a.sync()
        #expect(status.lastError == nil)
        #expect(status.oversizedThoughts == 1)
        #expect(status.pending == 1)
        await b.sync()
        #expect(try b.thought(other.id) != nil)
        #expect(try b.thought(huge.id) == nil)
    }

    @Test func anEntityTheServerStillRefusesAsTooLargeIsHeldNotThrown() async throws {
        var config = SyncEngine.Configuration()
        config.maxInlinePayload = 10_000_000
        config.maxRecordBytes = 10_000_000
        let a = try await SyncDevice("A", server: server, config: config)
        let b = try await SyncDevice("B", server: server)
        let refused = a.store.create(body: Self.bigBody(100_000), now: a.now(at(1)))
        let other = a.store.create(body: "small", now: a.now(at(2)))
        let status = await a.sync()
        #expect(status.lastError == nil)
        #expect(status.oversizedThoughts == 1)
        await b.sync()
        #expect(try b.thought(other.id) != nil)
        #expect(try b.thought(refused.id) == nil)
    }

    // MARK: Memory budgets

    @Test func planningAndResolvingStayWithinTheByteBudgets() async throws {
        var config = SyncEngine.Configuration()
        config.maxPlanBytes = 300_000
        config.maxApplyBytes = 300_000
        let a = try await SyncDevice("A", server: server, config: config)
        let b = try await SyncDevice("B", server: server, config: config)
        var ids: [UUID] = []
        for i in 0..<10 { ids.append(a.store.create(body: Self.bigBody(120_000), now: a.now(at(Double(i)))).id) }
        #expect(await a.sync().lastError == nil)
        #expect(await a.engine.peakPlannedBytes > 0)
        #expect(await a.engine.peakPlannedBytes <= 300_000)
        #expect(await b.sync().lastError == nil)
        #expect(try ids.allSatisfy { try b.thought($0) != nil })
        #expect(await b.engine.peakResolvedBytes > 0)
        #expect(await b.engine.peakResolvedBytes <= 300_000)
    }

    @Test func anOversizedThoughtIsNotResealedUntilItChanges() async throws {
        var config = SyncEngine.Configuration()
        config.maxRecordBytes = 100_000
        let a = try await SyncDevice("A", server: server, config: config)
        let huge = a.store.create(body: Self.bigBody(400_000), now: a.now(at(1)))
        for _ in 0..<3 { await a.sync() }
        #expect(await a.engine.recordsSealed == 1)
        a.store.update(huge, body: Self.bigBody(450_000), blocks: [], intervalDays: nil, now: a.now(at(2)))
        let status = await a.sync()
        #expect(await a.engine.recordsSealed == 2)
        #expect(status.oversizedThoughts == 1)
    }

    // MARK: Pointer edge cases

    func inject(recordKey: String, inner: Data, device: SyncDevice, storeBlob: Bool) async throws -> String {
        let name = device.keys.recordBlobName(recordKey: recordKey, hash: UUID().uuidString)
        if storeBlob { try await server.putBlob(name: name, data: try SyncCrypto.sealBlob(inner, vaultID: SyncDevice.vaultID, name: name, keys: device.keys)) }
        _ = await server.inject(recordKey: recordKey, payload: SyncCrypto.pointer(toBlob: name))
        return name
    }

    func futureTagFrame(_ name: String, device: SyncDevice) throws -> (key: String, frame: Data) {
        let payload = SyncPayload.tag(TagRecord(name: name, displayName: name.capitalized, colorHex: nil, updatedAt: nil))
        var text = String(decoding: try payload.encoded(), as: UTF8.self)
        text.removeLast(6)
        let key = device.keys.recordKey(type: .tag, entityID: name)
        let frame = try SyncCrypto.seal(Data((text + "\"v\":2}").utf8), vaultID: SyncDevice.vaultID, recordKey: key, payloadVersion: 2, keys: device.keys)
        return (key, frame)
    }

    @Test func aBadPointerBlobIsNotDownloadedEveryCycle() async throws {
        let b = try await SyncDevice("B", server: server)
        let key = b.keys.recordKey(type: .tag, entityID: "work")
        let name = try await inject(recordKey: key, inner: Data("not a record frame".utf8), device: b, storeBlob: false)
        await b.sync()
        #expect(try await b.state.parkedPointerCount() == 1)
        try await server.putBlob(name: name, data: try SyncCrypto.sealBlob(Data("not a record frame".utf8), vaultID: SyncDevice.vaultID, name: name, keys: b.keys))
        let before = await server.blobGets
        await b.sync()
        let afterFirst = await server.blobGets
        #expect(afterFirst == before + 1)
        await b.sync()
        #expect(await server.blobGets == afterFirst)
    }

    @Test func aPointerWhoseBlobIsMissingSurvivesAFullResync() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let big = a.store.create(body: Self.bigBody(200_000), now: a.now(at(1)))
        a.store.create(body: "other", now: a.now(at(2)))
        try await syncToQuiescence([a, b], server: server)
        a.store.update(try #require(try a.thought(big.id)), body: Self.bigBody(210_000), blocks: [], intervalDays: nil, now: a.now(at(3)))
        await a.sync()
        let saved = await server.removeAllBlobs()
        await server.prune(tombstonesBelow: await server.headSeq + 1)
        #expect(await b.sync().lastError == nil)
        #expect(try b.thought(big.id) != nil)
        await server.restoreBlobs(saved)
        try await syncToQuiescence([a, b], server: server)
        #expect(try b.thought(big.id)?.body.count == 210_000)
        try await b.expectClean()
    }

    @Test func aPointerToANewerVersionRecordParksTheFullPayloadAndAppliesAfterAnUpdate() async throws {
        let b = try await SyncDevice("B", server: server)
        let (key, frame) = try futureTagFrame("work", device: b)
        _ = try await inject(recordKey: key, inner: frame, device: b, storeBlob: true)
        await b.sync()
        #expect(try await b.state.parkedPointerCount() == 0)
        let parked = try await b.state.parked()
        #expect(parked.count == 1)
        #expect(parked.first?.payload == frame)

        var newer = SyncEngine.Configuration()
        newer.payloadVersion = 2
        b.makeEngine(config: newer)
        await b.sync()
        #expect(try await b.state.parkedCount() == 0)
        #expect(try b.context.fetch(FetchDescriptor<ThoughtReps.Tag>()).contains { $0.name == "work" })
    }

    @Test func tooLargeHalvesAMixedChunkAndHoldsOnlyTheRefusedThought() async throws {
        var config = SyncEngine.Configuration()
        config.maxInlinePayload = 10_000_000
        config.maxRecordBytes = 10_000_000
        let a = try await SyncDevice("A", server: server, config: config)
        let b = try await SyncDevice("B", server: server)
        var small: [UUID] = []
        for i in 0..<4 { small.append(a.store.create(body: "small \(i)", now: a.now(at(Double(i)))).id) }
        let refused = a.store.create(body: Self.bigBody(100_000), now: a.now(at(10)))
        for i in 4..<8 { small.append(a.store.create(body: "small \(i)", now: a.now(at(Double(i) + 20))).id) }
        let status = await a.sync()
        #expect(status.lastError == nil)
        #expect(status.oversizedThoughts == 1)
        await b.sync()
        #expect(try small.allSatisfy { try b.thought($0) != nil })
        #expect(try b.thought(refused.id) == nil)
    }

    @Test func statusCountsPointersAsBlockedAndNotAsUpdateRequired() async throws {
        let b = try await SyncDevice("B", server: server)
        let missing = b.keys.recordKey(type: .tag, entityID: "gone")
        _ = try await inject(recordKey: missing, inner: Data(), device: b, storeBlob: false)
        let onlyPointer = await b.sync()
        #expect(onlyPointer.updateRequired == false)
        #expect(onlyPointer.blockedThoughts == 1)

        let (key, frame) = try futureTagFrame("work", device: b)
        _ = try await inject(recordKey: key, inner: frame, device: b, storeBlob: true)
        let both = await b.sync()
        #expect(both.updateRequired == true)
        #expect(both.blockedThoughts == 1)
    }
}
