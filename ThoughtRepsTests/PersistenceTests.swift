import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

private final class BundleToken {}

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Real SQLite files: reopening, cascade deletes, and opening v1 on-disk data.
@MainActor
@Suite("Persistence")
struct PersistenceTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func roundTripThroughSQLiteFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("default.store")
        let viewedAt = now.addingTimeInterval(8 * 86_400)
        var keptID: UUID
        var deletedID: UUID

        do {
            let container = try ModelContainer.thoughtReps(url: url)
            defer { withExtendedLifetime(container) {} }
            let store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), ratingPrompt: .throwaway())
            let kept = store.create(
                body: "# Kept\n#Swift #café",
                blocks: [BlockDraft(title: "Q", content: "A"), BlockDraft(title: "", content: "B")],
                intervalDays: 3,
                now: now
            )
            store.markViewed(kept, now: viewedAt)
            store.setPinned(kept, true)
            let doomed = store.create(
                body: "# Doomed\n#swift",
                blocks: [BlockDraft(content: "gone")],
                now: now
            )
            keptID = kept.id
            deletedID = doomed.id
        }

        do {
            let container = try ModelContainer.thoughtReps(url: url)
            defer { withExtendedLifetime(container) {} }
            let context = container.mainContext
            let thoughts = try context.fetch(FetchDescriptor<Thought>())
            #expect(thoughts.count == 2)
            let kept = try #require(thoughts.first { $0.id == keptID })
            #expect(kept.body == "# Kept\n#Swift #café")
            #expect(kept.createdAt == now)
            #expect(kept.lastViewedAt == viewedAt)
            #expect(kept.viewCount == 1)
            #expect(kept.intervalDays == 3)
            #expect(kept.isPinned)
            #expect(!kept.isArchived)
            #expect(kept.sortedTags.map(\.name) == ["café", "swift"])
            #expect(kept.sortedTags.map(\.displayName) == ["café", "Swift"])
            #expect(kept.sortedBlocks.map(\.content) == ["A", "B"])
            #expect(kept.sortedBlocks.map(\.order) == [0, 1])
            #expect(kept.sortedBlocks.first?.title == "Q")
            #expect(kept.sortedBlocks.allSatisfy { $0.thought === kept })
            #expect(try IntegrityChecker.check(context).isEmpty)

            let doomed = try #require(thoughts.first { $0.id == deletedID })
            context.delete(doomed)
            try context.save()
        }

        do {
            let container = try ModelContainer.thoughtReps(url: url)
            defer { withExtendedLifetime(container) {} }
            let context = container.mainContext
            #expect(try context.fetchCount(FetchDescriptor<Thought>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<Block>()) == 2)
            #expect(try IntegrityChecker.check(context).isEmpty)
        }
    }

    @Test func largeImageSurvivesReopeningTheStore() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("default.store")
        var bytes = [UInt8](repeating: 0, count: 600_000)
        var rng = SeededGenerator(seed: 7)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &rng) }
        let big = ProcessedImage(data: Data(bytes), thumbnailData: Data(bytes.prefix(300_000)), width: 2048, height: 1536)
        let draft = ImageDraft(processed: big)

        do {
            let container = try ModelContainer.thoughtReps(url: url)
            defer { withExtendedLifetime(container) {} }
            let store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
            store.create(body: "# Big\n\(ImageToken.token(for: draft.id))", images: [draft], now: now)
        }
        do {
            let container = try ModelContainer.thoughtReps(url: url)
            defer { withExtendedLifetime(container) {} }
            let image = try #require(try container.mainContext.fetch(FetchDescriptor<ImageAsset>()).first)
            #expect(image.id == draft.id)
            #expect(image.data == big.data)
            #expect(image.thumbnailData == big.thumbnailData)
            #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
        }
    }

    @Test func openV1FixtureWithMigrationPlan() throws {
        let fixture = try #require(Bundle(for: BundleToken.self).url(forResource: "default", withExtension: "store"))
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("default.store")
        try FileManager.default.copyItem(at: fixture, to: url)

        let container = try ModelContainer.thoughtReps(url: url)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let thoughts = try context.fetch(FetchDescriptor<Thought>())
        #expect(thoughts.count == 4)

        func thought(_ prefix: String) throws -> Thought {
            try #require(thoughts.first { $0.body.hasPrefix(prefix) })
        }
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 86_400

        let pinned = try thought("# Pinned idea")
        #expect(pinned.isPinned)
        #expect(!pinned.isArchived)
        #expect(pinned.intervalDays == 3)
        #expect(pinned.createdAt == t0)
        #expect(pinned.sortedTags.map(\.name) == ["study", "swift"])
        #expect(pinned.sortedTags.map(\.displayName) == ["study", "Swift"])
        #expect(pinned.sortedBlocks.map(\.content) == ["Answer one", "Answer two"])
        #expect(pinned.sortedBlocks.map(\.title) == ["Quiz", nil])

        let viewed = try thought("# Viewed twice")
        #expect(viewed.viewCount == 2)
        #expect(viewed.lastViewedAt == t0.addingTimeInterval(17 * day))
        #expect(viewed.sortedTags.map(\.name) == ["café", "swift"])

        let archived = try thought("# Shelved")
        #expect(archived.isArchived)
        #expect(archived.archivedAt == t0.addingTimeInterval(20 * day))
        #expect(archived.sortedTags.map(\.name) == ["study"])
        #expect(archived.sortedBlocks.count == 1)

        let plain = try thought("# Plain")
        #expect((plain.tags ?? []).isEmpty)
        #expect((plain.blocks ?? []).isEmpty)

        let inlineImage = try #require(viewed.images?.first)
        #expect((viewed.images ?? []).count == 1)
        #expect(inlineImage.block == nil)
        #expect(viewed.orderedImages.map(\.id) == [inlineImage.id])
        #expect(viewed.body.contains(ImageToken.token(for: inlineImage.id)))
        #expect(inlineImage.width == 96 && inlineImage.height == 64)
        #expect(inlineImage.data?.isEmpty == false && inlineImage.thumbnailData?.isEmpty == false)

        let gallery = try #require(archived.sortedBlocks.first)
        #expect(gallery.kind == .gallery)
        #expect(gallery.title == "Trip")
        #expect(gallery.sortedImages.map(\.order) == [0, 1])
        #expect(gallery.sortedImages.map(\.width) == [64, 80])
        #expect(archived.firstImage === gallery.sortedImages.first)

        #expect(try context.fetchCount(FetchDescriptor<ThoughtReps.Tag>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 3)
        #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 3)

        #expect(pinned.sortedBlocks.map(\.kindRaw) == ["markdown", "markdown"])
        #expect(pinned.sortedBlocks.map(\.isBlurred) == [true, true])
        #expect(gallery.isBlurred == false)
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    @Test func legacyBlurredBlocksMigrateToBlurredMarkdown() throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        let context = container.mainContext
        let store = ThoughtStore(context: context, saveErrors: SaveErrorCenter())
        let thought = store.create(
            body: "Body",
            blocks: [BlockDraft(title: "Quiz", content: "One"), BlockDraft(content: "Two")],
            intervalDays: nil,
            now: now
        )
        for block in thought.sortedBlocks { block.kindRaw = BlockKind.legacyBlurredRaw }
        try context.save()

        #expect(BlockDraft.drafts(for: thought).map(\.isBlurred) == [true, true])
        #expect(BlockDraft.drafts(for: thought).map(\.kind) == [.markdown, .markdown])
        #expect(try IntegrityChecker.check(context).contains { $0.description.contains("legacy blurred") })

        #expect(store.migrateLegacyBlurredBlocks())
        #expect(thought.sortedBlocks.map(\.kindRaw) == ["markdown", "markdown"])
        #expect(thought.sortedBlocks.map(\.isBlurred) == [true, true])
        #expect(try IntegrityChecker.check(context).isEmpty)
        #expect(store.migrateLegacyBlurredBlocks())
    }
}

private struct DiskFull: LocalizedError {
    var errorDescription: String? { "The disk is full." }
}

@MainActor
@Suite("Save failures")
struct SaveFailureTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func failedSaveRollsBackAndReports() throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let errors = SaveErrorCenter()
        let good = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: errors)
        let thought = good.create(body: "# Keep\n#swift", now: now)
        #expect(errors.message == nil)

        let failing = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: errors, save: { _ in throw DiskFull() })
        failing.setPinned(thought, true)
        #expect(!thought.isPinned)
        #expect(errors.message == "The disk is full.")

        errors.dismiss()
        let detached = failing.create(body: "# Never saved\n#other", now: now)
        #expect(detached.modelContext == nil)
        #expect(try context.fetchCount(FetchDescriptor<Thought>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ThoughtReps.Tag>()) == 1)
        #expect(!context.hasChanges)
        #expect(errors.message == "The disk is full.")
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    @Test func retryAfterFailedCreateOrUpdatePersistsOnce() throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let errors = SaveErrorCenter()
        let failing = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: errors, save: { _ in throw DiskFull() })
        let good = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: errors)
        let drafts = [BlockDraft(title: "Q", content: "A")]

        let failedCreate = failing.create(body: "# New\n#swift", blocks: drafts, now: now)
        #expect(failedCreate.modelContext == nil)
        #expect(try context.fetchCount(FetchDescriptor<Thought>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 0)

        let created = good.create(body: "# New\n#swift", blocks: drafts, now: now)
        #expect(created.modelContext != nil)
        #expect(try context.fetchCount(FetchDescriptor<Thought>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ThoughtReps.Tag>()) == 1)

        let edited = [BlockDraft(title: "Q2", content: "A2"), BlockDraft(content: "B2")]
        #expect(!failing.update(created, body: "# Edited\n#swift", blocks: edited, intervalDays: 2, now: now))
        #expect(created.body == "# New\n#swift")
        #expect(created.intervalDays == nil)
        #expect(created.sortedBlocks.map(\.content) == ["A"])

        #expect(good.update(created, body: "# Edited\n#other", blocks: edited, intervalDays: 2, now: now))
        #expect(created.body == "# Edited\n#other")
        #expect(created.sortedBlocks.map(\.content) == ["A2", "B2"])
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 2)
        #expect(try IntegrityChecker.check(context).isEmpty)
    }

    struct Shape: Sendable, CustomTestStringConvertible {
        let before: Int
        let after: Int
        var testDescription: String { "\(before)->\(after) blocks" }
    }

    nonisolated static let shapes = [Shape(before: 1, after: 3), Shape(before: 1, after: 5), Shape(before: 2, after: 3),
                         Shape(before: 3, after: 4), Shape(before: 3, after: 1), Shape(before: 3, after: 0)]

    /// `update` saves in up to four steps (new tags, fields, block deletions, block additions).
    @Test(arguments: shapes, 1...4)
    func updateFailingAtAnySaveStepIsConsistentAndRetrySucceeds(shape: Shape, failingStep: Int) throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let errors = SaveErrorCenter()
        let good = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: errors)
        let thought = good.create(
            body: "# One\n#swift",
            blocks: (0..<shape.before).map { BlockDraft(content: "b\($0)") },
            now: now
        )
        let drafts = (0..<shape.after).map { BlockDraft(content: "n\($0)") }
        let edited = "# One\n#other"

        var calls = 0
        let flaky = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: errors, save: {
            calls += 1
            if calls == failingStep { throw DiskFull() }
            try $0.save()
        })
        let succeeded = flaky.update(thought, body: edited, blocks: drafts, intervalDays: 2, now: now)
        let failure = "step \(failingStep) of \(shape.testDescription)"
        #expect(try IntegrityChecker.check(context).isEmpty, Comment(rawValue: failure))
        let orders = thought.sortedBlocks.map(\.order)
        #expect(orders == Array(0..<orders.count), Comment(rawValue: failure))
        if succeeded {
            #expect(thought.sortedBlocks.map(\.content) == drafts.map(\.content), Comment(rawValue: failure))
        }

        #expect(good.update(thought, body: edited, blocks: drafts, intervalDays: 2, now: now))
        #expect(thought.body == edited)
        #expect(thought.intervalDays == 2)
        #expect(thought.sortedBlocks.map(\.content) == drafts.map(\.content), Comment(rawValue: failure))
        #expect(thought.sortedBlocks.map(\.order) == Array(0..<shape.after), Comment(rawValue: failure))
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == shape.after, Comment(rawValue: failure))
        #expect(thought.sortedTags.map(\.name) == ["other"], Comment(rawValue: failure))
        #expect(try IntegrityChecker.check(context).isEmpty, Comment(rawValue: failure))
    }

    @Test func failedDeleteRestoresThoughtAndBlocks() throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let errors = SaveErrorCenter()
        let good = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: errors)
        let failing = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: errors, save: { _ in throw DiskFull() })
        let thought = good.create(body: "# One\n#swift", blocks: [BlockDraft(content: "A")], now: now)

        #expect(!failing.delete(thought))
        #expect(!failing.deleteAll())
        #expect(thought.sortedBlocks.map(\.content) == ["A"])
        #expect(try context.fetchCount(FetchDescriptor<Thought>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 1)
        #expect(try IntegrityChecker.check(context).isEmpty)

        #expect(good.delete(thought))
        #expect(try context.fetchCount(FetchDescriptor<Block>()) == 0)
    }

    @Test func pruneAndDeleteAllGoThroughTheSamePath() throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let errors = SaveErrorCenter()
        let good = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: errors)
        let thought = good.create(body: "# One\n#swift", now: now)
        good.update(thought, body: "# One", blocks: [], intervalDays: nil, now: now)
        let failing = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: errors, save: { _ in throw DiskFull() })

        failing.pruneOrphanTags()
        #expect(errors.message != nil)
        #expect(try context.fetchCount(FetchDescriptor<ThoughtReps.Tag>()) == 1)

        errors.dismiss()
        failing.deleteAll()
        #expect(errors.message != nil)
        #expect(try context.fetchCount(FetchDescriptor<Thought>()) == 1)
    }
}

/// The checker itself must notice each kind of damage, or the randomized tests prove nothing.
@MainActor
@Suite("IntegrityChecker")
struct IntegrityCheckerTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func violations(after damage: (ModelContext, Thought) -> Void) throws -> [String] {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        defer { withExtendedLifetime(container) {} }
        let context = container.mainContext
        let store = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
        let thought = store.create(body: "# T\n#swift", blocks: [BlockDraft(content: "a")], now: now)
        #expect(try IntegrityChecker.check(context).isEmpty)
        damage(context, thought)
        return try IntegrityChecker.check(context).map(\.description)
    }

    @Test func cleanContextHasNoViolations() throws {
        let container = try ModelContainer.thoughtReps(inMemory: true)
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test func detectsTagMismatch() throws {
        let found = try violations { _, thought in thought.body = "# T\n#other" }
        #expect(found.contains { $0.contains("tags") })
    }

    @Test func detectsBadTags() throws {
        let found = try violations { context, _ in
            context.insert(ThoughtReps.Tag(name: "Swift", displayName: ""))
            context.insert(ThoughtReps.Tag(name: "swift", displayName: "swift"))
        }
        #expect(found.contains { $0.contains("not lowercased NFC") })
        #expect(found.contains { $0.contains("empty displayName") })
        #expect(found.contains { $0.contains("Duplicate tag name") })
    }

    @Test func detectsOrphanBlockAndImage() throws {
        let found = try violations { context, _ in
            context.insert(Block(kind: .markdown, content: "x", order: 0))
            context.insert(ImageAsset(data: Data([1]), thumbnailData: Data([1]), width: 1, height: 1))
        }
        #expect(found.contains { $0.contains("Block") && $0.contains("no thought") })
        #expect(found.contains { $0.contains("Image") && $0.contains("no thought") })
    }

    @Test func detectsBlockOrderGap() throws {
        let found = try violations { _, thought in thought.blocks?.first?.order = 2 }
        #expect(found.contains { $0.contains("block orders") })
    }

    @Test func detectsArchiveStateErrors() throws {
        let archivedAndPinned = try violations { _, thought in
            thought.isArchived = true
            thought.isPinned = true
        }
        #expect(archivedAndPinned.contains { $0.contains("archived and pinned") })
        #expect(archivedAndPinned.contains { $0.contains("without archivedAt") })
        let stray = try violations { _, thought in thought.archivedAt = now }
        #expect(stray.contains { $0.contains("not archived but has archivedAt") })
    }

    @Test func detectsScheduleErrors() throws {
        let found = try violations { _, thought in
            thought.viewCount = 1
            thought.updatedAt = thought.createdAt.addingTimeInterval(-1)
            thought.intervalDays = 0
        }
        #expect(found.contains { $0.contains("no lastViewedAt") })
        #expect(found.contains { $0.contains("updatedAt") })
        #expect(found.contains { $0.contains("out of range") })
        let negative = try violations { _, thought in thought.viewCount = -1 }
        #expect(negative.contains { $0.contains("negative viewCount") })
    }

    @Test func orphanTagsAreAllowed() throws {
        let found = try violations { context, _ in
            context.insert(ThoughtReps.Tag(name: "lonely", displayName: "lonely"))
        }
        #expect(found.isEmpty)
    }
}
