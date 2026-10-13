import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

@MainActor
@Suite("Linked thoughts")
struct LinkedThoughtsTests {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let store: ThoughtStore
    let rating = RatingPrompt.throwaway()
    let isolated = IsolatedDefaults()
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let later = Date(timeIntervalSince1970: 1_790_100_000)

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        store = ThoughtStore(
            context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: isolated.pendingImageSaves, ratingPrompt: rating
        )
    }

    func links(of thought: Thought) -> [UUID] {
        thought.sortedBlocks.filter { $0.kind == .thoughtLink }.compactMap(\.linkedThoughtID)
    }

    func failingStore(after saves: Int) -> ThoughtStore {
        var left = saves
        var failing = store
        failing.save = { context in
            if left == 0 { throw InjectedSaveFailure() }
            left -= 1
            try context.save()
        }
        return failing
    }

    // MARK: Store

    @Test func addingALinkAppendsABlockAndBumpsOnlyTheContentClock() throws {
        let hub = store.create(body: "# Hub", blocks: [BlockDraft(content: "text")], now: now)
        let other = store.create(body: "# Other", now: now)
        let schedule = hub.scheduleChangedAt, state = hub.stateChangedAt, due = hub.nextDueAt

        #expect(store.addLink(to: other.id, in: hub, now: later))
        let link = try #require(hub.sortedBlocks.last)
        #expect(link.kind == .thoughtLink && link.linkedThoughtID == other.id && link.order == 1)
        #expect(link.content.isEmpty && link.title == nil && !link.isBlurred && (link.images ?? []).isEmpty)
        #expect(hub.updatedAt == later)
        #expect(hub.scheduleChangedAt == schedule && hub.stateChangedAt == state && hub.nextDueAt == due)
        #expect(other.updatedAt == now)
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    @Test func selfLinksAndDuplicatesAreRejectedWithoutWriting() throws {
        let hub = store.create(body: "# Hub", now: now)
        let other = store.create(body: "# Other", now: now)
        #expect(!store.addLink(to: hub.id, in: hub, now: later))
        #expect(store.addLink(to: other.id, in: hub, now: later))
        #expect(!store.addLink(to: other.id, in: hub, now: later.addingTimeInterval(5)))
        #expect(links(of: hub) == [other.id])
        #expect(hub.updatedAt == later)
    }

    @Test func removingALinkRenumbersAndBumpsUpdatedAt() throws {
        let a = store.create(body: "# A", now: now), b = store.create(body: "# B", now: now)
        let hub = store.create(body: "# Hub", blocks: [BlockDraft(content: "first")], now: now)
        store.addLink(to: a.id, in: hub, now: now)
        store.addLink(to: b.id, in: hub, now: now)

        #expect(store.removeLink(to: a.id, in: hub, now: later))
        #expect(links(of: hub) == [b.id])
        #expect(hub.sortedBlocks.map(\.order) == [0, 1])
        #expect(hub.updatedAt == later)
        #expect(store.removeLink(to: a.id, in: hub, now: later.addingTimeInterval(9)))
        #expect(hub.updatedAt == later)
        #expect(try IntegrityChecker.check(context).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 2)
    }

    @Test func linkBlocksSurviveAnEditAndReorderThroughDrafts() throws {
        let a = store.create(body: "# A", now: now), b = store.create(body: "# B", now: now)
        let hub = store.create(body: "# Hub", blocks: [BlockDraft(content: "text")], now: now)
        store.addLink(to: a.id, in: hub, now: now)
        store.addLink(to: b.id, in: hub, now: now)
        let ids = hub.sortedBlocks.map(\.id)

        var drafts = BlockDraft.drafts(for: hub)
        #expect(drafts.map(\.linkedThoughtID) == [nil, a.id, b.id])
        #expect(store.update(hub, body: "# Hub", blocks: drafts, intervalDays: nil, now: later))
        #expect(hub.sortedBlocks.map(\.id) == ids)
        #expect(links(of: hub) == [a.id, b.id])

        drafts.reverse()
        #expect(store.update(hub, body: "# Hub", blocks: drafts, intervalDays: nil, now: later.addingTimeInterval(1)))
        #expect(hub.sortedBlocks.map(\.id) == ids.reversed())
        #expect(links(of: hub) == [b.id, a.id])

        drafts.removeFirst()
        #expect(store.update(hub, body: "# Hub", blocks: drafts, intervalDays: nil, now: later.addingTimeInterval(2)))
        #expect(links(of: hub) == [a.id])
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    @Test func draftsCanAddLinksButNotSelfDuplicateOrTargetlessOnes() throws {
        let other = store.create(body: "# Other", now: now)
        let hub = store.create(body: "# Hub", now: now)
        func drafts(self id: UUID) -> [BlockDraft] {
            [
                BlockDraft(kind: .thoughtLink, title: "ignored", content: "ignored", isBlurred: true, linkedThoughtID: other.id),
                BlockDraft(kind: .thoughtLink, linkedThoughtID: other.id),
                BlockDraft(kind: .thoughtLink, linkedThoughtID: id),
                BlockDraft(kind: .thoughtLink),
            ]
        }
        #expect(store.update(hub, body: "# Hub", blocks: drafts(self: hub.id), intervalDays: nil, now: later))
        #expect(links(of: hub) == [other.id])
        let link = try #require(hub.sortedBlocks.first)
        #expect(link.content.isEmpty && link.title == nil && !link.isBlurred)

        let created = store.create(body: "# New", blocks: [], now: now)
        let createdDrafts = drafts(self: created.id)
        #expect(store.update(created, body: "# New", blocks: createdDrafts, intervalDays: nil, now: later))
        #expect(links(of: created) == [other.id])
        let elsewhere = UUID()
        let fresh = store.create(body: "# Fresh", blocks: drafts(self: elsewhere), now: now)
        #expect(links(of: fresh) == [other.id, elsewhere])
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    @Test func failedLinkWritesLeaveTheStoreConsistent() throws {
        let other = store.create(body: "# Other", now: now)
        let hub = store.create(body: "# Hub", now: now)
        let bumped = later.addingTimeInterval(1)
        #expect(!failingStore(after: 0).addLink(to: other.id, in: hub, now: bumped))
        #expect(hub.updatedAt == now && links(of: hub).isEmpty)
        #expect(!failingStore(after: 1).addLink(to: other.id, in: hub, now: bumped))
        #expect(hub.updatedAt == bumped && links(of: hub).isEmpty)
        #expect(try IntegrityChecker.check(context).isEmpty)

        store.addLink(to: other.id, in: hub, now: later)
        let bumpedAgain = later.addingTimeInterval(2)
        #expect(!failingStore(after: 0).removeLink(to: other.id, in: hub, now: bumpedAgain))
        #expect(hub.updatedAt == later && links(of: hub) == [other.id])
        #expect(!failingStore(after: 1).removeLink(to: other.id, in: hub, now: bumpedAgain))
        #expect(hub.updatedAt == bumpedAgain && links(of: hub) == [other.id])
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    @Test func deletingATargetLeavesTheLinkingThoughtAlone() throws {
        let target = store.create(body: "# Target", now: now)
        let hub = store.create(body: "# Hub", now: now)
        store.addLink(to: target.id, in: hub, now: now)
        let targetID = target.id
        #expect(store.delete(target, now: later))
        #expect(links(of: hub) == [targetID])
        #expect(hub.updatedAt == now)
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    @Test func linkBlocksAddNoSearchText() throws {
        let other = store.create(body: "# Zebra stripes", now: now)
        let hub = store.create(body: "# Hub", now: now)
        let before = SearchDocument(hub)
        store.addLink(to: other.id, in: hub, now: later)
        let after = SearchDocument(hub)
        #expect(after.blocks == before.blocks && after.body == before.body)
    }

    // MARK: Visits

    @Test func aVisitCountsAsAViewAndNothingElse() throws {
        let thought = store.create(body: "# T", now: now)
        let learner = store.create(body: "# L", learn: true, now: now)
        store.review(learner, gotIt: true, now: learner.nextDueAt)
        let promptCount = rating.dueOpenCount
        for item in [thought, learner] {
            let due = item.nextDueAt, interval = item.intervalDays, wait = item.learnIntervalDays
            let schedule = item.scheduleChangedAt, updated = item.updatedAt, views = item.viewCount

            #expect(store.recordVisit(item, now: later))
            #expect(item.viewCount == views + 1 && item.lastViewedAt == later)
            #expect(item.nextDueAt == due && item.intervalDays == interval && item.learnIntervalDays == wait)
            #expect(item.scheduleChangedAt == schedule && item.updatedAt == updated)
        }
        #expect(rating.dueOpenCount == promptCount)
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    @Test func aFailedVisitRollsBack() throws {
        let thought = store.create(body: "# T", now: now)
        #expect(!failingStore(after: 0).recordVisit(thought, now: later))
        #expect(thought.viewCount == 0 && thought.lastViewedAt == nil)
    }

    // MARK: Queries

    @Test func targetsResolvePresentArchivedAndMissingIdsInOneFetch() throws {
        let live = store.create(body: "# Live", now: now)
        let shelved = store.create(body: "# Shelved", now: now)
        store.archive(shelved, now: now)
        let found = ThoughtCounts.targets(of: [live.id, shelved.id, UUID()], in: context)
        #expect(Set(found.keys) == [live.id, shelved.id])
        #expect(ThoughtCounts.targets(of: [], in: context).isEmpty)
    }

    @Test func linkedFromListsActiveSourcesNewestFirstAndCountsAll() throws {
        let target = store.create(body: "# Target", now: now)
        let older = store.create(body: "# Older", now: now)
        let newer = store.create(body: "# Newer", now: now)
        let shelved = store.create(body: "# Shelved", now: now)
        let unrelated = store.create(body: "# Unrelated", now: now)
        store.addLink(to: target.id, in: older, now: now.addingTimeInterval(10))
        store.addLink(to: target.id, in: newer, now: now.addingTimeInterval(20))
        store.addLink(to: target.id, in: shelved, now: now.addingTimeInterval(30))
        store.addLink(to: older.id, in: unrelated, now: now)
        store.archive(shelved, now: now)

        let result = ThoughtCounts.linkedFrom(target.id, in: context)
        #expect(result.thoughts.map(\.id) == [newer.id, older.id])
        #expect(result.total == 2)
        #expect(ThoughtCounts.linkedFrom(unrelated.id, in: context).total == 0)
    }

    @Test func linkedFromCapsTheListButCountsEveryone() throws {
        let target = store.create(body: "# Target", now: now)
        let total = ThoughtCounts.linkedFromLimit + 3
        for index in 0..<total {
            let source = store.create(body: "# S\(index)", now: now)
            store.addLink(to: target.id, in: source, now: now.addingTimeInterval(Double(index)))
        }
        let result = ThoughtCounts.linkedFrom(target.id, in: context)
        #expect(result.thoughts.count == ThoughtCounts.linkedFromLimit)
        #expect(result.total == total)
        #expect(result.thoughts.first?.title == "S\(total - 1)")
    }

    // MARK: Integrity

    @Test func integrityCheckerFlagsBadLinkBlocks() throws {
        let hub = store.create(body: "# Hub", now: now)
        let other = store.create(body: "# Other", now: now)
        store.addLink(to: other.id, in: hub, now: now)
        let link = try #require(hub.blocks?.first)
        #expect(try IntegrityChecker.check(context).isEmpty)

        func violations(_ change: (Block) -> Void, undo: (Block) -> Void) throws -> [String] {
            change(link)
            defer { undo(link) }
            return try IntegrityChecker.check(context).map(\.description)
        }
        #expect(try violations({ $0.linkedThoughtID = nil }, undo: { $0.linkedThoughtID = other.id }).contains { $0.contains("no linkedThoughtID") })
        #expect(try violations({ $0.linkedThoughtID = hub.id }, undo: { $0.linkedThoughtID = other.id }).contains { $0.contains("own thought") })
        #expect(try violations({ $0.content = "x" }, undo: { $0.content = "" }).contains { $0.contains("has content") })
        #expect(try violations({ $0.title = "x" }, undo: { $0.title = nil }).contains { $0.contains("has content") })
        #expect(try violations({ $0.isBlurred = true }, undo: { $0.isBlurred = false }).contains { $0.contains("has content") })

        let note = Block(kind: .markdown, content: "text", order: 1)
        context.insert(note)
        note.thought = hub
        note.linkedThoughtID = other.id
        #expect(try IntegrityChecker.check(context).contains { $0.description.contains("Non-link block") })
        note.linkedThoughtID = nil

        let twin = Block(kind: .thoughtLink, content: "", order: 2, linkedThoughtID: other.id)
        context.insert(twin)
        twin.thought = hub
        #expect(try IntegrityChecker.check(context).contains { $0.description.contains("twice") })
    }

    @Test func danglingLinksAreNotViolations() throws {
        let hub = store.create(body: "# Hub", now: now)
        store.addLink(to: UUID(), in: hub, now: now)
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    // MARK: Backup

    func link(to target: UUID?, id: UUID = UUID(), order: Int = 0) -> BlockRecord {
        BlockRecord(
            id: id, kindRaw: BlockKind.thoughtLink.rawValue, title: nil, content: "", order: order, images: [], linkedThoughtID: target
        )
    }

    @Test func linkRecordsFollowTheValidationRules() {
        let id = UUID(), target = UUID()
        #expect(record(id: id, blocks: [link(to: target)]).isImportable)
        #expect(record(id: id, blocks: [link(to: target), link(to: UUID(), order: 1)]).isImportable)
        #expect(!record(id: id, blocks: [link(to: nil)]).isImportable)
        #expect(!record(id: id, blocks: [link(to: id)]).isImportable)
        #expect(!record(id: id, blocks: [link(to: target), link(to: target, order: 1)]).isImportable)

        var withContent = link(to: target)
        withContent.content = "x"
        #expect(!record(blocks: [withContent]).isImportable)
        var blurred = link(to: target)
        blurred.isBlurred = true
        #expect(!record(blocks: [blurred]).isImportable)
        var titled = link(to: target)
        titled.title = "x"
        #expect(!record(blocks: [titled]).isImportable)
        var withImage = link(to: target)
        withImage.images = [ImageRecord(id: UUID(), width: 10, height: 10, order: 0)]
        #expect(!record(blocks: [withImage]).isImportable)

        let stray = BlockRecord(id: UUID(), kindRaw: "markdown", title: nil, content: "x", order: 0, images: [], linkedThoughtID: target)
        #expect(!record(blocks: [stray]).isImportable)
    }

    @Test func recordsFromBeforeLinksDecodeWithoutTheField() throws {
        let plain = BlockRecord(id: UUID(), kindRaw: "markdown", title: nil, content: "x", order: 0, images: [])
        let data = try BackupFormat.encoder().encode(record(blocks: [plain]))
        #expect(!String(decoding: data, as: UTF8.self).contains("linkedThoughtID"))
        let decoded = try BackupFormat.decoder().decode(ThoughtRecord.self, from: data)
        #expect(decoded.blocks.first?.linkedThoughtID == nil)
    }

    @Test func linksRoundTripThroughAnExportIncludingDanglingOnes() async throws {
        let destination = try ModelContainer.thoughtReps(inMemory: true)
        let destinationStore = ThoughtStore(
            context: destination.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: isolated.pendingImageSaves
        )
        let kept = store.create(body: "# Kept", now: now)
        let hub = store.create(body: "# Hub", blocks: [BlockDraft(content: "text")], now: now)
        let gone = UUID()
        store.addLink(to: kept.id, in: hub, now: now)
        store.addLink(to: gone, in: hub, now: now)
        let hubID = hub.id, keptID = kept.id

        let file = try BackupExporter(container: container, appVersion: "1.0", build: "1").export(now: now)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preflight = try BackupImporter.preflight(fileURL: file)
        let plan = try BackupImporter.plan(preflight, container: destination)
        var tally = ImportTally()
        for try await batch in BackupImporter.batches(for: plan) {
            #expect(destinationStore.importThoughts(batch.thoughts, tags: preflight.tags, tally: &tally))
        }
        #expect(tally.added == 2 && tally.rejected == 0)

        let copy = try #require(try destination.mainContext.fetch(FetchDescriptor<Thought>(predicate: #Predicate { $0.id == hubID })).first)
        #expect(links(of: copy) == [keptID, gone])
        #expect(copy.sortedBlocks.map(\.order) == [0, 1, 2])
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
    }

    @Test func aNewerImportedRecordReplacesLinks() async throws {
        let first = UUID(), second = UUID()
        let hub = store.create(body: "# Hub", now: now)
        store.addLink(to: first, in: hub, now: now)
        let newer = record(id: hub.id, createdAt: now, updatedAt: later, blocks: [link(to: second)])
        var tally = ImportTally()
        #expect(store.importThoughts([ImportedThought(record: newer, images: [:])], tags: [], tally: &tally))
        #expect(tally.replaced == 1)
        #expect(links(of: hub) == [second])
        #expect(try IntegrityChecker.check(context).isEmpty)
    }
}
