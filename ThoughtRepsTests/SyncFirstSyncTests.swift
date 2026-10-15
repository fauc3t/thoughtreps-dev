import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Sync first sync and triggers")
struct SyncFirstSyncTests {
    let server = FakeSyncServer()
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// Inserts thoughts in one save, much faster than `create` for thousands.
    func fill(_ device: SyncDevice, count: Int) throws {
        for index in 0..<count {
            let created = at(Double(index))
            device.context.insert(Thought(body: "thought \(index)", createdAt: created, nextDueAt: created.addingTimeInterval(86_400 * 7)))
        }
        try device.context.save()
    }

    @Test func aLargeFirstSyncPagesPushesAndResumesAfterAnInterruption() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server, config: .paged(pull: 100))
        let count = 2500
        try fill(a, count: count)
        try await a.reconcile()
        #expect(try await a.state.outboxCount() == count + 1, "every thought and the settings record is queued")

        await server.failNextCall(after: 12)
        let interrupted = await a.sync()
        #expect(interrupted.lastError != nil)
        let pending = interrupted.pending
        #expect(pending > 0 && pending < count)

        // B joins mid-upload and gets what is there.
        await b.sync()
        let partial = try b.thoughts().count
        #expect(partial > 0 && partial < count)

        // The app was killed: a new engine over the same sync.sqlite finishes the job.
        a.makeEngine()
        let finished = await a.sync()
        #expect(finished.lastError == nil)
        #expect(finished.pending == 0)
        #expect(await server.liveRecordCount == count * 2 + 1)
        #expect(await server.recordPushes.values.allSatisfy { $0 == 1 }, "nothing was uploaded twice")
        let batches = await server.events.compactMap { event -> Int? in if case .push(let keys) = event { keys.count } else { nil } }
        #expect(batches.allSatisfy { $0 <= SyncLimits.maxRecordsPerPush })
        #expect(batches.count < count / 20)

        await b.sync()
        #expect(try b.thoughts().count == count)
        #expect(try a.canonicalDump() == b.canonicalDump())
        try await b.expectClean()
    }

    @Test func aSecondDeviceJoiningWhileTheFirstUploadsKeepsPullingUntilCaughtUp() async throws {
        let a = try await SyncDevice("A", server: server, config: .paged(pull: 50, push: 10))
        let b = try await SyncDevice("B", server: server, config: .paged(pull: 7))
        try fill(a, count: 120)
        try await a.reconcile()
        var rounds = 0
        while try await a.state.outboxCount() > 0, rounds < 40 {
            await server.failNextCall(after: 3)
            await a.sync()
            await b.sync()
            rounds += 1
        }
        await a.sync()
        await b.sync()
        #expect(try a.thoughts().count == 120)
        #expect(try a.canonicalDump() == b.canonicalDump())
    }

    // MARK: Triggers

    func waitUntil(_ message: String, _ condition: @escaping () async -> Bool) async {
        for _ in 0..<2000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting for \(message)")
    }

    @Test func aCycleRunsTwoSecondsAfterTheLastLocalChange() async throws {
        let a = try await SyncDevice("A", server: server)
        let sleeper = ManualSleeper()
        let triggers = SyncTriggers(engine: a.engine, sleep: { try await sleeper.sleep($0) })
        await triggers.start(observing: a.state)

        a.store.create(body: "first", now: at(0))
        await waitUntil("the debounce to start") { await sleeper.sleepCalls >= 2 }
        await sleeper.advance(by: .seconds(1))
        a.store.create(body: "second", now: at(1))
        await waitUntil("the debounce to restart") { await sleeper.sleepCalls >= 3 }
        await sleeper.advance(by: .milliseconds(1500))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.pushCalls == 0, "1.5 s after the second change is not yet 2 s")
        await sleeper.advance(by: .milliseconds(600))
        await waitUntil("the cycle") { await server.pushCalls == 1 }
        #expect(await server.liveRecordCount == 4, "both thoughts went in one cycle")
        await triggers.stop(observing: a.state)
    }

    @Test func theHeadCheckRunsACycleOnlyWhenTheHeadMoved() async throws {
        let a = try await SyncDevice("A", server: server)
        let b = try await SyncDevice("B", server: server)
        let sleeper = ManualSleeper()
        let triggers = SyncTriggers(engine: a.engine, sleep: { try await sleeper.sleep($0) })
        await triggers.start(observing: a.state)
        await waitUntil("the head loop to sleep") { await sleeper.waiting == 1 }

        await sleeper.advance(by: .seconds(30))
        await waitUntil("the first cycle") { await server.pullCalls == 1 }
        await waitUntil("the head loop to sleep again") { await sleeper.waiting == 1 }
        await sleeper.advance(by: .seconds(30))
        await waitUntil("a second head check") { await server.headCalls == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await server.pullCalls == 1, "the head didn't move, so no cycle")

        let thought = b.store.create(body: "from B", now: b.now(at(0)))
        await b.sync()
        await waitUntil("the head loop to sleep again") { await sleeper.waiting == 1 }
        await sleeper.advance(by: .seconds(30))
        await waitUntil("the thought to arrive") { (try? a.thought(thought.id)) != nil }
        await triggers.stop(observing: a.state)
    }
}
