import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

/// Several devices make random changes (content only on the thoughts they created, meta and settings on anything),
/// sync in random order against a server that drops responses and fails calls, with injected save failures and
/// clocks that disagree. After syncing to quiescence every device must hold the same thoughts, and the integrity
/// and search checkers must be clean.
@MainActor
@Suite("Sync convergence")
struct SyncConvergenceTests {
    nonisolated static let seeds: [UInt64] = Array(1...40) + [45, 76]
    static let steps = 160
    static let clockOffsets: [TimeInterval] = [0, -3 * 3600, 1800]
    static let pullLimits = [2, 5, 50]

    func summary(_ devices: [SyncDevice]) throws -> String {
        try devices.map { "\($0.name): \(try $0.thoughts().count)" }.joined(separator: ", ")
    }

    /// Content changes only on the thoughts a device created: concurrent edits of one thought are the merge's job.
    @Test(arguments: seeds)
    func devicesEndUpIdentical(seed: UInt64) async throws {
        try await converge(seed: seed, editsAnyThought: false)
    }

    /// Any device edits or deletes any thought, so the same thought is edited concurrently. Until the merge exists
    /// this only has to converge (the later edit wins whole) and keep every checker clean.
    @Test(arguments: seeds)
    func devicesConvergeWhenEditingTheSameThoughts(seed: UInt64) async throws {
        try await converge(seed: seed, editsAnyThought: true)
    }

    private func converge(seed: UInt64, editsAnyThought: Bool) async throws {
        let server = FakeSyncServer()
        let count = Self.clockOffsets.count
        var devices: [SyncDevice] = []
        for index in 0..<count {
            devices.append(try await SyncDevice(
                "D\(index)", server: server, clockOffset: Self.clockOffsets[index],
                config: .paged(pull: Self.pullLimits[index], push: [3, 10, 49][index])
            ))
        }
        var rng = SeededGenerator(seed: seed)
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        var owned: [Set<UUID>] = Array(repeating: [], count: count)
        var deleted = Set<UUID>()
        var log: [String] = []

        for step in 0..<Self.steps {
            now = now.addingTimeInterval(Double(Int.random(in: 1...90, using: &rng)))
            let index = Int.random(in: 0..<count, using: &rng)
            let device = devices[index]
            let t = device.now(now)
            let all = try device.thoughts().sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            let mine = editsAnyThought ? all : all.filter { owned[index].contains($0.id) }
            let target = all.randomElement(using: &rng)
            let own = mine.randomElement(using: &rng)
            let op = Int.random(in: 0..<24, using: &rng)
            let injectFailure = Int.random(in: 0..<25, using: &rng) == 0
            if injectFailure { device.failSaves = Int.random(in: 1...2, using: &rng) }
            var description = "op \(op)"

            switch op {
            case 0, 1, 2:
                var body = RandomizedOperationTests.randomBody(&rng)
                var images: [ImageDraft] = []
                if Int.random(in: 0..<3, using: &rng) == 0 {
                    let image = newImage(UInt8.random(in: 0...255, using: &rng))
                    images = [image]
                    body += "\n" + ImageToken.token(for: image.id)
                }
                if Int.random(in: 0..<30, using: &rng) == 0 { body += "\n" + String(repeating: "large ", count: 15_000) }
                var blocks: [BlockDraft] = []
                if Int.random(in: 0..<4, using: &rng) == 0 { blocks.append(BlockDraft(kind: .gallery, images: [newImage(UInt8.random(in: 0...255, using: &rng))])) }
                if Int.random(in: 0..<5, using: &rng) == 0 { blocks.append(fileBlock(fakeFile(UInt8.random(in: 0...255, using: &rng)))) }
                if Int.random(in: 0..<3, using: &rng) == 0 { blocks.append(BlockDraft(content: "block \(Int.random(in: 0..<100, using: &rng)) #blocktag")) }
                let created = device.store.create(
                    body: body, blocks: blocks, images: images, intervalDays: RandomizedOperationTests.randomInterval(&rng),
                    learn: Int.random(in: 0..<5, using: &rng) == 0, now: t
                )
                if created.modelContext != nil { owned[index].insert(created.id) }
                description = "create"
            case 3, 4:
                if let own {
                    var (body, images) = RandomizedOperationTests.withInlineImages(RandomizedOperationTests.randomBody(&rng), &rng)
                    if Int.random(in: 0..<30, using: &rng) == 0 { body += "\n" + String(repeating: "large ", count: 15_000) }
                    var blocks = RandomizedOperationTests.currentDrafts(of: own)
                    if Bool.random(using: &rng) { blocks += RandomizedOperationTests.randomBlocks(&rng, linkable: all.map(\.id)) }
                    device.store.update(own, body: body, blocks: blocks, images: images, intervalDays: RandomizedOperationTests.randomInterval(&rng), now: t)
                }
                description = "update"
            case 5, 6:
                if let target { device.store.markViewed(target, now: t) }
                description = "markViewed"
            case 7:
                if let target { device.store.snooze(target, days: Int.random(in: 1...30, using: &rng), now: t) }
                description = "snooze"
            case 8:
                if let target { device.store.setPinned(target, Bool.random(using: &rng), now: t) }
                description = "pin"
            case 9:
                if let target { device.store.archive(target, now: t) }
                description = "archive"
            case 10:
                if let target, target.isArchived { device.store.restore(target, now: t) }
                description = "restore"
            case 11:
                if let target, target.intervalMode == .learn {
                    device.store.review(target, gotIt: Bool.random(using: &rng), now: t)
                } else if let target {
                    device.store.setLearnMode(target, true, now: t)
                }
                description = "learn"
            case 12:
                if let target { device.store.setInterval(target, days: RandomizedOperationTests.randomInterval(&rng), now: t) }
                description = "setInterval"
            case 13:
                if let own, Int.random(in: 0..<3, using: &rng) == 0 {
                    let doomed = own.id
                    if device.store.delete(own, now: t) {
                        owned[index].remove(doomed)
                        deleted.insert(doomed)
                    }
                }
                description = "delete"
            case 14:
                if let own {
                    var blocks = RandomizedOperationTests.currentDrafts(of: own)
                    blocks.append(BlockDraft(kind: .gallery, images: [newImage(UInt8.random(in: 0...255, using: &rng))]))
                    device.store.update(own, body: own.body, blocks: blocks, intervalDays: own.intervalDays, now: t)
                }
                description = "add gallery"
            case 15:
                if let own, let target { device.store.addLink(to: target.id, in: own, now: t) }
                description = "add link"
            case 16:
                if let tag = try device.context.fetch(FetchDescriptor<ThoughtReps.Tag>(sortBy: [SortDescriptor(\.name)])).randomElement(using: &rng) {
                    device.store.setColor(tag, hex: RandomizedOperationTests.colorChoices.randomElement(using: &rng)!, now: t)
                }
                description = "setColor"
            case 17:
                device.defaults.set(Int.random(in: 1...30, using: &rng), forKey: AppSettings.Key.defaultIntervalDays)
                AppSettings.recordDefaultIntervalChange(now: t, defaults: device.defaults, sync: device.state)
                description = "settings"
            case 18:
                device.store.pruneOrphanTags()
                description = "pruneOrphanTags"
            case 19:
                if Int.random(in: 0..<3, using: &rng) == 0 { await server.prune(tombstonesBelow: await server.headSeq + 1) }
                description = "server prunes tombstones"
            default:
                // A sync, sometimes with the server or a save misbehaving.
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: await server.failNextCall(after: Int.random(in: 0..<4, using: &rng))
                case 1: await server.dropNextPushResponse()
                case 2: device.failSaves = 1
                default: break
                }
                let status = await device.sync()
                description = "sync (error: \(status.lastError ?? "-"))"
            }
            device.failSaves = 0
            await server.clearFailures()
            log.append("\(step) \(device.name) \(description)")
        }

        await server.clearFailures()
        try await syncToQuiescence(devices, server: server, maxRounds: 25)

        let tail = log.suffix(12).joined(separator: "\n")
        let reference = try devices[0].canonicalDump()
        let counts = try summary(devices)
        for device in devices {
            let dump = try device.canonicalDump()
            let difference = Set(dump).symmetricDifference(reference).sorted().map { String($0.prefix(120)) }
            #expect(dump == reference, "seed \(seed): \(device.name) differs from D0 (\(counts))\n\(difference.joined(separator: "\n"))\n\(tail)")
            #expect(try await device.state.outboxCount() == 0, "seed \(seed): \(device.name) still has queued changes")
            #expect(try await device.state.heldCount() == 0, "seed \(seed): \(device.name) still holds records")
            let status = await device.engine.status
            #expect(status.lastError == nil && status.attention == nil, "seed \(seed): \(device.name) \(status)")
            try await device.expectClean("seed \(seed)")
            let drift = try await device.reconcile()
            #expect(drift.thoughts == 0 && drift.deletions == 0, "seed \(seed): \(device.name) the reconciler finds thoughts out of step with sync.sqlite: \(drift)")
        }
        let ids = Set(try devices[0].thoughts().map(\.id))
        if !editsAnyThought {
            #expect(ids.isDisjoint(with: deleted), "seed \(seed): a deleted thought came back, even after the server pruned its tombstone")
        }
        #expect(await server.liveThoughtIDs(keys: devices[0].keys, vaultID: SyncDevice.vaultID) == ids, "seed \(seed): the server holds the same thoughts")
    }

    /// Not just that the devices agree: whoever wrote last wins, on every device, even from a lagging clock.
    @Test func theLastWriteWinsOnEveryDeviceForAScriptedSequence() async throws {
        let server = FakeSyncServer()
        var devices: [SyncDevice] = []
        for index in 0..<3 {
            devices.append(try await SyncDevice("D\(index)", server: server, clockOffset: Self.clockOffsets[index]))
        }
        let owner = devices[1]
        var now = Date(timeIntervalSince1970: 1_790_000_000)
        let id = owner.store.create(body: "scripted", now: owner.now(now)).id
        try await syncToQuiescence(devices, server: server)

        for round in 0..<6 {
            now = now.addingTimeInterval(120)
            let device = devices[round % 3]
            let copy = try #require(try device.thought(id))
            let pinned = round % 2 == 0
            device.store.setPinned(copy, !pinned, now: device.now(now))
            device.store.setPinned(copy, pinned, now: device.now(now.addingTimeInterval(1)))
            device.store.snooze(copy, days: 2, now: device.now(now.addingTimeInterval(2)))
            device.store.snooze(copy, days: 5 + round, now: device.now(now.addingTimeInterval(3)))
            var body = "scripted"
            if device === owner {
                device.store.update(copy, body: "round \(round) first", blocks: [], intervalDays: nil, now: device.now(now.addingTimeInterval(4)))
                device.store.update(copy, body: "round \(round) last", blocks: [], intervalDays: nil, now: device.now(now.addingTimeInterval(5)))
                body = "round \(round) last"
            }
            let due = copy.nextDueAt
            try await syncToQuiescence(devices, server: server)
            for other in devices {
                let seen = try #require(try other.thought(id))
                #expect(seen.isPinned == pinned, "round \(round): \(other.name) pin")
                #expect(seen.nextDueAt == due, "round \(round): \(other.name) snooze")
                if device === owner { #expect(seen.body == body, "round \(round): \(other.name) body") }
            }
        }
    }
}
