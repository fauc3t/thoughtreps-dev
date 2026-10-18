import Foundation
import Testing
@testable import ThoughtReps

/// Forwards to the fake server, but holds one kind of call until the calling task is cancelled (the engine's `stop()` cancels
/// it), so a test ends the engine mid-cycle with no race between the stop and the call returning.
private actor GatedTransport: SyncTransport {
    enum Call { case pull, push }

    private let server: FakeSyncServer
    private var held: Call?
    private var blocked = false
    private(set) var pushes = 0

    init(_ server: FakeSyncServer) { self.server = server }

    nonisolated var supportsBlobs: Bool { true }

    func hold(_ call: Call) { held = call }

    /// False if the call was not reached within five seconds.
    func waitUntilBlocked() async -> Bool {
        for _ in 0..<2500 where !blocked {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return blocked
    }

    private func gate(_ call: Call) async {
        guard held == call else { return }
        blocked = true
        for _ in 0..<2500 where !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func pull(after cursor: Int64, limit: Int) async throws -> PullPage {
        await gate(.pull)
        return try await server.pull(after: cursor, limit: limit)
    }

    func push(_ records: [PushRecord], epoch: Int64) async throws -> PushResult {
        pushes += 1
        await gate(.push)
        return try await server.push(records, epoch: epoch)
    }

    func head() async throws -> SyncHead { try await server.head() }
    func putBlob(name: String, data: Data, epoch: Int64) async throws { try await server.putBlob(name: name, data: data, epoch: epoch) }
    func getBlob(name: String, epoch: Int64, maxBytes: Int) async throws -> Data { try await server.getBlob(name: name, epoch: epoch, maxBytes: maxBytes) }
    func hasBlob(name: String, epoch: Int64) async throws -> Bool { try await server.hasBlob(name: name, epoch: epoch) }
    func startGarbageCollection(liveList: Data, epoch: Int64, asOfSeq: Int64) async throws -> GarbageCollectionStart {
        try await server.startGarbageCollection(liveList: liveList, epoch: epoch, asOfSeq: asOfSeq)
    }
}

@MainActor
@Suite("Sync engine stop")
struct SyncEngineStopTests {
    @Test func stoppingMidPullAppliesAndCommitsNothingAndTheEraseRunsAfterTheCycleEnded() async throws {
        let server = FakeSyncServer()
        let gated = GatedTransport(server)
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server, transport: gated)
        a.store.create(body: "from A", now: a.now(Date(timeIntervalSince1970: 1_790_000_000)))
        await a.sync()

        await gated.hold(.pull)
        let cycle = Task { await b.sync() }
        #expect(await gated.waitUntilBlocked())
        await b.engine.stop()
        await cycle.value

        #expect(try b.thoughts().isEmpty, "the pulled page was not applied")
        #expect(try await b.state.cursor() == 0, "no cursor was written")
        #expect(try await b.state.recordCount() == 0)

        #expect(b.store.deleteAll())
        await b.sync()
        #expect(try b.thoughts().isEmpty, "a stopped engine runs no more cycles")
    }

    @Test func stoppingMidPushRecordsNothingAndSendsNoFurtherBatches() async throws {
        let server = FakeSyncServer()
        let gated = GatedTransport(server)
        let b = try await SyncDevice("B", server: server, transport: gated, config: .paged(pull: 50, push: 1))
        let now = b.now(Date(timeIntervalSince1970: 1_790_000_000))
        b.store.create(body: "one", now: now)
        b.store.create(body: "two", now: now)
        await b.state.flush()

        try await b.reconcile()
        let queued = try await b.state.outboxCount()
        #expect(queued >= 2)
        await gated.hold(.push)
        let cycle = Task { await b.sync() }
        #expect(await gated.waitUntilBlocked())
        await b.engine.stop()
        await cycle.value

        #expect(await gated.pushes == 1, "no batch after the one in flight")
        #expect(try await b.state.outboxCount() == queued, "nothing was dequeued")
        #expect(try await b.state.recordCount() == 0, "no synced record was written")
    }
}
