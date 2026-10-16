import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// The fake with the HTTP server's limits: no blob routes.
struct NoBlobTransport: SyncTransport {
    let base: FakeSyncServer

    var supportsBlobs: Bool { false }
    func push(_ records: [PushRecord], epoch: Int64) async throws -> PushResult { try await base.push(records, epoch: epoch) }
    func pull(after cursor: Int64, limit: Int) async throws -> PullPage { try await base.pull(after: cursor, limit: limit) }
    func head() async throws -> SyncHead { try await base.head() }
    func putBlob(name: String, data: Data, epoch: Int64) async throws { throw SyncTransportError.unsupported }
    func getBlob(name: String, maxBytes: Int) async throws -> Data { throw SyncTransportError.unsupported }
    func hasBlob(name: String, epoch: Int64) async throws -> Bool { throw SyncTransportError.unsupported }
}

/// Answers every call the way the server does to a request it will never accept.
actor RefusingTransport: SyncTransport {
    let status: Int
    private(set) var calls = 0

    init(status: Int = 401) { self.status = status }

    func push(_ records: [PushRecord], epoch: Int64) async throws -> PushResult { throw refusal() }
    func pull(after cursor: Int64, limit: Int) async throws -> PullPage { throw refusal() }
    func head() async throws -> SyncHead { throw refusal() }
    func putBlob(name: String, data: Data, epoch: Int64) async throws { throw refusal() }
    func getBlob(name: String, maxBytes: Int) async throws -> Data { throw refusal() }
    func hasBlob(name: String, epoch: Int64) async throws -> Bool { throw refusal() }

    private func refusal() -> SyncTransportError {
        calls += 1
        return .refused(status: status, message: "Unauthorized")
    }
}

@MainActor
@Suite("Sync engine over HTTP transport")
struct SyncHTTPEngineTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func aTransportWithoutBlobsHoldsBackBigRecordsAndAttachmentsAndSyncsTheRest() async throws {
        let transport = NoBlobTransport(base: server)
        let a = try await SyncDevice("A", server: server, transport: transport)
        let b = try await SyncDevice("B", server: server)
        let small = a.store.create(body: "small #text", now: a.now(at(0)))
        let big = a.store.create(body: SyncLargeRecordTests.bigBody(300_000), now: a.now(at(1)))
        let image = newImage(3)
        let pictured = a.store.create(body: "picture " + ImageToken.token(for: image.id), images: [image], now: a.now(at(2)))
        let status = await a.sync()
        #expect(status.lastError == nil && status.attention == nil)
        #expect(status.waitingForBlobs == 2 && status.oversizedThoughts == 0, "the big record and the thought with an image wait")
        #expect(await server.blobs.isEmpty)
        await b.sync()
        #expect(try b.thought(small.id)?.body == "small #text")
        #expect(try b.thought(big.id) == nil && b.thought(pictured.id) == nil)
        #expect(try await a.state.outboxCount() == 2, "held thoughts stay queued")

        let again = await a.sync()
        #expect(again.lastError == nil && again.waitingForBlobs == 2)
        a.store.update(small, body: "small, edited", blocks: [], intervalDays: nil, now: a.now(at(10)))
        #expect(await a.sync().lastError == nil)
        await b.sync()
        #expect(try b.thought(small.id)?.body == "small, edited")
    }

    @Test func heldThoughtsFlowOnceTheTransportSupportsBlobs() async throws {
        let a = try await SyncDevice("A", server: server, transport: NoBlobTransport(base: server))
        let b = try await SyncDevice("B", server: server)
        let big = a.store.create(body: SyncLargeRecordTests.bigBody(300_000), now: a.now(at(0)))
        let image = newImage(4)
        let pictured = a.store.create(body: "picture " + ImageToken.token(for: image.id), images: [image], now: a.now(at(1)))
        #expect(await a.sync().waitingForBlobs == 2)
        await b.sync()
        #expect(try b.thoughts().isEmpty)

        a.transport = server
        a.makeEngine()
        let status = await a.sync()
        #expect(status.lastError == nil && status.waitingForBlobs == 0)
        #expect(try await a.state.outboxCount() == 0)
        await b.sync()
        #expect(try b.thought(big.id)?.body.count == 300_000)
        #expect(try b.thought(pictured.id)?.images?.count == 1)
        try await b.expectClean()
    }

    @Test func aDeviceWithoutBlobsPullsPastBlobRecordsHoldsThemAndAppliesTheRest() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server, transport: NoBlobTransport(base: server))
        let big = a.store.create(body: SyncLargeRecordTests.bigBody(300_000), now: a.now(at(0)))
        let image = newImage(5)
        let pictured = a.store.create(body: "picture " + ImageToken.token(for: image.id), images: [image], now: a.now(at(1)))
        let small = a.store.create(body: "after the blobs", now: a.now(at(2)))
        #expect(await a.sync().lastError == nil)

        let status = await b.sync()
        #expect(status.lastError == nil && status.attention == nil)
        #expect(try b.thought(small.id)?.body == "after the blobs", "records after the blob ones still apply")
        #expect(try b.thought(big.id) == nil && b.thought(pictured.id) == nil)
        #expect(status.blockedThoughts > 0)

        a.store.update(small, body: "edited later", blocks: [], intervalDays: nil, now: a.now(at(10)))
        await a.sync()
        let later = await b.sync()
        #expect(later.lastError == nil)
        #expect(try b.thought(small.id)?.body == "edited later")

        b.transport = server
        b.makeEngine()
        #expect(await b.sync().lastError == nil)
        #expect(try b.thought(big.id)?.body.count == 300_000)
        #expect(try b.thought(pictured.id) != nil)
        try await b.expectClean()
    }

    @Test func aRefusedRequestStopsTheEngineInsteadOfLoopingEveryCycle() async throws {
        let refusing = RefusingTransport()
        let a = try await SyncDevice("A", server: server, transport: refusing)
        a.store.create(body: "one", now: a.now(at(0)))
        let status = await a.sync()
        #expect(status.attention == .serverRefused(status: 401, message: "Unauthorized"))
        #expect(status.phase == .stopped)
        let calls = await refusing.calls
        let again = await a.sync()
        #expect(again.attention != nil)
        #expect(await a.engine.syncIfHeadMoved() == false)
        #expect(await refusing.calls == calls, "a stopped engine makes no more requests")
        #expect(try await a.state.outboxCount() > 0)
    }

    @Test func aGoneAnswerStopsTheEngineLikeAnyRefusal() async throws {
        let a = try await SyncDevice("A", server: server, transport: RefusingTransport(status: 410))
        a.store.create(body: "one", now: a.now(at(0)))
        let status = await a.sync()
        #expect(status.attention == .serverRefused(status: 410, message: "Unauthorized"))
        #expect(status.phase == .stopped)
    }

    @Test func aRefusedHeadCheckStopsTheEngineToo() async throws {
        let refusing = RefusingTransport()
        let a = try await SyncDevice("A", server: server, transport: refusing)
        #expect(await a.engine.syncIfHeadMoved() == false)
        #expect(await a.engine.status.attention == .serverRefused(status: 401, message: "Unauthorized"))
    }
}

@MainActor
@Suite("Sync engines against the local server", .enabled(if: HTTPTestServer.isConfigured, "set TEST_RUNNER_THOUGHTREPS_SYNC_TEST_URL and TEST_RUNNER_THOUGHTREPS_SYNC_TEST_SECRET (a local sync server, see DEVELOPMENT.md)"))
struct SyncLocalServerEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func twoEnginesOverHTTPConverge() async throws {
        let vault = "t-" + UUID().uuidString.lowercased()
        let transport = try await HTTPTestServer.transport(vault: vault)
        let unused = FakeSyncServer()
        let a = try await SyncDevice("A", server: unused, transport: transport, vault: vault)
        let b = try await SyncDevice("B", server: unused, transport: transport, vault: vault)

        let keep = a.store.create(body: "keep #one", intervalDays: 3, now: a.now(at(0)))
        let edit = a.store.create(body: "edit me", now: a.now(at(1)))
        let doomed = a.store.create(body: "doomed", now: a.now(at(2)))
        for i in 0..<60 { a.store.create(body: "bulk \(i)", now: a.now(at(10 + Double(i)))) }
        #expect(await a.sync().lastError == nil)
        #expect(await b.sync().lastError == nil)
        #expect(try b.thoughts().count == 63)

        b.store.update(try #require(try b.thought(edit.id)), body: "edited on B", blocks: [], intervalDays: nil, now: b.now(at(100)))
        b.store.delete(try #require(try b.thought(doomed.id)), now: b.now(at(101)))
        a.store.setPinned(keep, true, now: a.now(at(102)))
        #expect(await b.sync().lastError == nil)
        #expect(await a.sync().lastError == nil)
        #expect(await b.sync().lastError == nil)
        #expect(try a.thought(edit.id)?.body == "edited on B")
        #expect(try a.thought(doomed.id) == nil)
        #expect(try b.thought(keep.id)?.isPinned == true)
        #expect(try a.canonicalDump() == b.canonicalDump())
        try await a.expectClean()
        try await b.expectClean()
        #expect(try await a.state.outboxCount() == 0)
        #expect(try await b.state.outboxCount() == 0)
    }

    @Test func overlappingEditsOverHTTPMakeAConflictCopyOnBothDevices() async throws {
        let vault = "t-" + UUID().uuidString.lowercased()
        let transport = try await HTTPTestServer.transport(vault: vault)
        let unused = FakeSyncServer()
        let a = try await SyncDevice("A", server: unused, transport: transport, vault: vault)
        let b = try await SyncDevice("B", server: unused, transport: transport, vault: vault)
        let thought = a.store.create(body: "start", now: a.now(at(0)))
        await a.sync()
        await b.sync()
        a.store.update(thought, body: "A's version", blocks: [], intervalDays: nil, now: a.now(at(10)))
        b.store.update(try #require(try b.thought(thought.id)), body: "B's version", blocks: [], intervalDays: nil, now: b.now(at(20)))
        for _ in 0..<3 {
            #expect(await a.sync().lastError == nil)
            #expect(await b.sync().lastError == nil)
        }
        #expect(try a.thoughts().count == 2 && b.thoughts().count == 2)
        #expect(try a.canonicalDump() == b.canonicalDump())
        try await a.expectClean()
        try await b.expectClean()
    }

    @Test func aDeviceThatMissedAnEraseStopsInsteadOfRefillingTheVault() async throws {
        let vault = "t-" + UUID().uuidString.lowercased()
        let transport = try await HTTPTestServer.transport(vault: vault)
        let unused = FakeSyncServer()
        let a = try await SyncDevice("A", server: unused, transport: transport, vault: vault)
        a.store.create(body: "one", now: a.now(at(0)))
        #expect(await a.sync().lastError == nil)
        let epoch = try await transport.eraseVault()
        a.store.create(body: "two", now: a.now(at(5)))
        let status = await a.sync()
        #expect(status.attention == .epochChanged(known: epoch - 1, server: epoch))
        #expect(try await transport.head().liveRecordCount == 0)
    }
}
