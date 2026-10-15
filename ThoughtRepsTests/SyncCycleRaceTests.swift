import Foundation
import SwiftData
import Testing
import os
@testable import ThoughtReps

/// Forwards to the real local store, but first lets the "user" make a random local change at the await points of a cycle.
final class RaceLocal: SyncLocalStore, @unchecked Sendable {
    private let inner: SyncLocalStore
    private let interfere: @Sendable @MainActor () -> Void
    init(_ inner: SyncLocalStore, interfere: @escaping @Sendable @MainActor () -> Void) { self.inner = inner; self.interfere = interfere }
    private func maybe() async { await MainActor.run { interfere() } }
    func snapshots(of entities: [SyncEntity]) async throws -> [SyncSnapshot] { await maybe(); return try await inner.snapshots(of: entities) }
    func blobBytes(_ refs: [BlobRef]) async throws -> [BlobRef: Data] { await maybe(); return try await inner.blobBytes(refs) }
    func missingBlobs(for contents: [ThoughtContentRecord]) async throws -> Set<BlobRef> { await maybe(); return try await inner.missingBlobs(for: contents) }
    func apply(_ batch: RemoteBatch, now: Date) async -> RemoteOutcome { await maybe(); return await inner.apply(batch, now: now) }
    func discardUnchanged(_ expected: [String: String], now: Date) async -> Bool { await maybe(); return await inner.discardUnchanged(expected, now: now) }
    func reconcile() async { await maybe(); await inner.reconcile() }
}

@MainActor
/// Local writes land at every await of a sync cycle (between pulling, applying, snapshotting and pushing); devices still converge.
@Suite("Sync cycle races")
struct SyncCycleRaceTests {
    nonisolated static let seeds: [UInt64] = Array(1...6)

    @Test(arguments: seeds)
    func convergesWithWritesInsideCycles(seed: UInt64) async throws {
        try await converge(seed: seed, harsh: false)
    }

    /// The same, with the transport failing calls, the server pruning tombstones (so a pull answers 410), and a write landing
    /// inside the transport's push call itself, between the snapshot and the acknowledgement.
    @Test(arguments: seeds)
    func convergesWithWritesInsidePushesFailuresAnd410s(seed: UInt64) async throws {
        try await converge(seed: seed, harsh: true)
    }

    private func converge(seed: UInt64, harsh: Bool) async throws {
        let server = FakeSyncServer()
        var devices: [SyncDevice] = []
        let offsets: [TimeInterval] = [0, -3 * 3600, 1800]
        for index in 0..<3 {
            devices.append(try await SyncDevice("D\(index)", server: server, clockOffset: offsets[index], config: .paged(pull: [2, 5, 50][index], push: [3, 10, 49][index])))
        }
        var rng = SeededGenerator(seed: seed)
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        var log: [String] = []

        func randomOp(_ device: SyncDevice, _ rng: inout SeededGenerator, at t: Date) throws -> String {
            let all = try device.thoughts().sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            let target = all.randomElement(using: &rng)
            switch Int.random(in: 0..<9, using: &rng) {
            case 0, 1:
                var body = RandomizedOperationTests.randomBody(&rng)
                var images: [ImageDraft] = []
                if Int.random(in: 0..<3, using: &rng) == 0 {
                    let image = newImage(UInt8.random(in: 0...255, using: &rng)); images = [image]; body += "\n" + ImageToken.token(for: image.id)
                }
                device.store.create(body: body, images: images, intervalDays: RandomizedOperationTests.randomInterval(&rng), now: t)
                return "create"
            case 2, 3:
                if let target {
                    let (body, images) = RandomizedOperationTests.withInlineImages(RandomizedOperationTests.randomBody(&rng), &rng)
                    device.store.update(target, body: body, blocks: RandomizedOperationTests.currentDrafts(of: target), images: images, intervalDays: target.intervalDays, now: t)
                }
                return "update"
            case 4: if let target { device.store.markViewed(target, now: t) }; return "view"
            case 5: if let target { device.store.setPinned(target, Bool.random(using: &rng), now: t) }; return "pin"
            case 6: if let target { device.store.snooze(target, days: Int.random(in: 1...30, using: &rng), now: t) }; return "snooze"
            case 7: if let target { device.store.delete(target, now: t) }; return "delete"
            default: if let target { device.store.archive(target, now: t) }; return "archive"
            }
        }

        for step in 0..<80 {
            now = now.addingTimeInterval(Double(Int.random(in: 1...90, using: &rng)))
            let device = devices[Int.random(in: 0..<3, using: &rng)]
            let t = device.now(now)
            if Int.random(in: 0..<2, using: &rng) == 0 {
                let d = try randomOp(device, &rng, at: t)
                log.append("\(step) \(device.name) \(d)")
            }
            // A sync during which the user also writes, at random await points.
            var interferenceRng = SeededGenerator(seed: seed &* 7919 &+ UInt64(step))
            let tick = OSAllocatedBox(0)
            let interfere: @Sendable @MainActor () -> Void = { [device] in
                guard Int.random(in: 0..<4, using: &interferenceRng) == 0 else { return }
                tick.value += 1
                if let d = try? randomOp(device, &interferenceRng, at: device.now(now.addingTimeInterval(Double(tick.value)))) { log.append("\(step) \(device.name) inside-sync \(d)") }
            }
            device.makeEngine(wrap: { inner in RaceLocal(inner, interfere: interfere) })
            if Int.random(in: 0..<6, using: &rng) == 0 { await server.dropNextPushResponse() }
            if harsh {
                if Int.random(in: 0..<5, using: &rng) == 0 { await server.failNextCall(after: Int.random(in: 0..<5, using: &rng)) }
                if Int.random(in: 0..<7, using: &rng) == 0 { await server.prune(tombstonesBelow: await server.headSeq + 1) }
                if Int.random(in: 0..<3, using: &rng) == 0 {
                    await server.beforeNextPush { await interfere() }
                }
            }
            await device.sync()
            await server.clearFailures()
        }
        for device in devices { device.makeEngine() }
        try await syncToQuiescence(devices, server: server, maxRounds: 30)
        let reference = try devices[0].canonicalDump()
        for device in devices {
            #expect(try device.canonicalDump() == reference, "seed \(seed): \(device.name) differs\n\(log.suffix(10).joined(separator: "\n"))")
            #expect(try await device.state.outboxCount() == 0, "seed \(seed): \(device.name) outbox")
            let status = await device.engine.status
            #expect(status.lastError == nil, "seed \(seed): \(device.name) \(status)")
            try await device.expectClean("seed \(seed)")
            let drift = try await device.reconcile()
            #expect(drift.thoughts == 0, "seed \(seed): \(device.name) drift \(drift)")
        }
    }
}

private final class OSAllocatedBox: @unchecked Sendable { var value: Int; init(_ v: Int) { value = v } }
