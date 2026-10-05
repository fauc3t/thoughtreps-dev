import Foundation
import SwiftData
import Testing
@testable import ThoughtReps

private struct DiskFull: Error {}

/// A UserDefaults suite of its own, removed when the owning test finishes.
final class IsolatedDefaults {
    let suiteName = "test-\(UUID())"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var pendingImageSaves: PendingImageSaves { PendingImageSaves(defaults: defaults) }
}

@MainActor
@Suite("Pending image saves")
struct PendingImageSaveTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let container: ModelContainer
    let context: ModelContext
    let isolated = IsolatedDefaults()
    let good: ThoughtStore

    var defaults: UserDefaults { isolated.defaults }

    init() throws {
        container = try ModelContainer.thoughtReps(inMemory: true)
        context = container.mainContext
        good = ThoughtStore(
            context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: isolated.pendingImageSaves
        )
    }

    /// A store whose saves numbered in `failing` (counted from 1 across its lifetime) throw.
    func store(failing: Set<Int>, onSave: (() -> Void)? = nil) -> ThoughtStore {
        var count = 0
        var store = ThoughtStore(context: context, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(), save: {
            count += 1
            onSave?()
            if failing.contains(count) { throw DiskFull() }
            try $0.save()
        })
        store.pendingImageSaves = PendingImageSaves(defaults: defaults)
        return store
    }

    var marker: Set<UUID> { PendingImageSaves(defaults: defaults).ids }

    func violations() throws -> [String] {
        try IntegrityChecker.check(context).map(\.description)
    }

    /// Saves: 1 the new image, 2 the body edit, 3 the take-back.
    func addImage(using store: ThoughtStore, to thought: Thought) -> Bool {
        let image = newImage(4)
        return store.update(
            thought, body: "# T\n\(ImageToken.token(for: image.id))", blocks: [], images: [image], intervalDays: nil, now: now
        )
    }

    @Test func happyPathLeavesNoMarker() throws {
        let thought = good.create(body: "# T", now: now)
        #expect(addImage(using: good, to: thought))
        #expect(marker.isEmpty)
        #expect(try violations().isEmpty)
    }

    @Test func failedBodySaveWithSuccessfulTakeBackLeavesNoMarker() throws {
        let thought = good.create(body: "# T", now: now)
        #expect(!addImage(using: store(failing: [2]), to: thought))
        #expect(marker.isEmpty)
        #expect((thought.images ?? []).isEmpty)
        #expect(try violations().isEmpty)
    }

    @Test func failedImageSaveLeavesNoMarker() throws {
        let thought = good.create(body: "# T", now: now)
        #expect(!addImage(using: store(failing: [1]), to: thought))
        #expect(marker.isEmpty)
        #expect(try violations().isEmpty)
    }

    @Test func bodySaveAndTakeBackBothFailingIsRecoveredByCleanup() throws {
        let thought = good.create(body: "# T", now: now)
        #expect(!addImage(using: store(failing: [2, 3]), to: thought))
        #expect(marker == [thought.id])
        #expect(try violations().contains { $0.hasPrefix("Inline image") })

        #expect(good.cleanUpPendingImageSaves())
        #expect(marker.isEmpty)
        #expect(try violations().isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 0)
        #expect(thought.body == "# T")
    }

    @Test func cleanupRecoversAnAppKilledBetweenTheSteps() throws {
        let thought = good.create(body: "# T", now: now)
        // The state `update` leaves if the process dies after saving the image and before the body edit.
        good.pendingImageSaves.insert(thought.id)
        let orphan = ImageAsset(data: Data([1]), thumbnailData: Data([1]), width: 1, height: 1)
        context.insert(orphan)
        orphan.thought = thought
        try context.save()
        #expect(try violations().contains { $0.hasPrefix("Inline image") })

        good.cleanUpPendingImageSaves()
        #expect(marker.isEmpty)
        #expect(try violations().isEmpty)
    }

    @Test func cleanupKeepsImagesThatHaveTokensAndGalleryImages() throws {
        let inline = newImage(1)
        let thought = good.create(
            body: "# T\n\(ImageToken.token(for: inline.id))",
            blocks: [BlockDraft(kind: .gallery, images: [newImage(2)])],
            images: [inline],
            now: now
        )
        good.pendingImageSaves.insert(thought.id)
        good.cleanUpPendingImageSaves()
        #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
        #expect(marker.isEmpty)
    }

    /// Proves no save happens and nothing is left pending; that nothing is fetched is by construction
    /// (the empty check comes first), not observable here.
    @Test func cleanupWithNoMarkerMakesNoSaves() throws {
        good.create(body: "# T", now: now)
        var saves = 0
        let counting = store(failing: [], onSave: { saves += 1 })
        #expect(counting.cleanUpPendingImageSaves())
        #expect(saves == 0)
        #expect(!context.hasChanges)
    }

    /// Saves of the next update on a marked thought: 1 removing the orphan, then 2 the new image,
    /// 3 the body edit, 4 the take-back.
    @Test func aMarkedThoughtIsHealedBeforeLaterUpdatesAndNeverLosesItsMarkerEarly() throws {
        let thought = good.create(body: "# T", now: now)
        #expect(!addImage(using: store(failing: [2, 3]), to: thought))
        #expect((thought.images ?? []).count == 1)

        #expect(!addImage(using: store(failing: [1]), to: thought))
        #expect(marker == [thought.id])
        #expect((thought.images ?? []).count == 1)
        #expect(try violations().contains { $0.hasPrefix("Inline image") })

        #expect(!addImage(using: store(failing: [2]), to: thought))
        #expect(marker.isEmpty)
        #expect((thought.images ?? []).isEmpty)
        #expect(try violations().isEmpty)
    }

    @Test func launchCleanupRemovesTheOrphanOfAMarkedThoughtAfterFailedEdits() throws {
        let thought = good.create(body: "# T", now: now)
        #expect(!addImage(using: store(failing: [2, 3]), to: thought))
        #expect(!addImage(using: store(failing: [1]), to: thought))
        #expect(!addImage(using: store(failing: [1]), to: thought))
        #expect(marker == [thought.id])

        #expect(good.cleanUpPendingImageSaves())
        #expect(marker.isEmpty)
        #expect((thought.images ?? []).isEmpty)
        #expect(try violations().isEmpty)
    }

    @Test func aSuccessfulUpdateRemovesTheOrphanAndTheMarker() throws {
        let thought = good.create(body: "# T", now: now)
        #expect(!addImage(using: store(failing: [2, 3]), to: thought))
        #expect(addImage(using: good, to: thought))
        #expect(marker.isEmpty)
        #expect((thought.images ?? []).count == 1)
        #expect(try violations().isEmpty)
    }

    @Test func markersForDeletedThoughtsAreJustCleared() throws {
        good.pendingImageSaves.insert(UUID())
        #expect(good.cleanUpPendingImageSaves())
        #expect(marker.isEmpty)
    }

    @Test func failedCleanupKeepsTheMarkerAndALaterRunFinishes() throws {
        let thought = good.create(body: "# T", now: now)
        #expect(!addImage(using: store(failing: [2, 3]), to: thought))

        #expect(!store(failing: [1]).cleanUpPendingImageSaves())
        #expect(marker == [thought.id])
        #expect(try violations().contains { $0.hasPrefix("Inline image") })

        #expect(good.cleanUpPendingImageSaves())
        #expect(marker.isEmpty)
        #expect(try violations().isEmpty)
    }
}
