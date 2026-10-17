import Foundation
import SwiftData
import os

/// An image or file a content record references. Blobs are immutable, so the id is enough.
struct BlobRef: Hashable, Sendable {
    var kind: SyncBlobKind
    var id: UUID
}

/// One outbox entity as the store has it now: the records to push, or none when there is nothing (a tag that
/// is gone, a thought with neither a row nor a tombstone).
struct SyncSnapshot: Sendable {
    var entity: SyncEntity
    var payloads: [SyncPayload]
    /// The blobs the thought's content record references; they go up before it does.
    var blobs: [BlobRef] = []
}

/// What the engine needs from the local store, all of it on the main actor behind this boundary.
protocol SyncLocalStore: Sendable {
    func snapshots(of entities: [SyncEntity]) async throws -> [SyncSnapshot]
    /// The bytes of stored images and files, by ref. Missing ones are left out.
    func blobBytes(_ refs: [BlobRef]) async throws -> [BlobRef: Data]
    /// Which of the blobs `contents` reference the store doesn't hold.
    func missingBlobs(for contents: [ThoughtContentRecord]) async throws -> Set<BlobRef>
    func apply(_ batch: RemoteBatch, now: Date) async -> RemoteOutcome
    /// Every image and file the store holds, archived thoughts' included, or nil when there are more than `limit`.
    func allBlobRefs(limit: Int) async throws -> [BlobRef]?
    /// Queues whatever the store has that `sync.sqlite` doesn't show as synced.
    func reconcile() async
}

/// How downloaded blob bytes become what the store keeps: the thumbnails are regenerated, not synced.
struct SyncBlobCodec: Sendable {
    var image: @Sendable (Data) throws -> ProcessedImage
    var file: @Sendable (Data, FileRecord) throws -> FileDraft

    static let live = SyncBlobCodec(
        image: { try ImageProcessor.importable($0) },
        file: { data, record in
            guard data.count == record.byteCount else { throw FileProcessingError.sizeMismatch }
            var draft = try FileProcessor.process(data: data, filename: record.filename, typeIdentifier: record.typeIdentifier)
            draft.id = record.id
            return draft
        }
    )
}

/// Reads image and file bytes with a context of its own, so the main actor never does.
@ModelActor
actor SyncBlobReader {
    func bytes(for refs: [BlobRef]) throws -> [BlobRef: Data] {
        let context = ModelContext(modelContainer)
        let imageIDs = refs.filter { $0.kind == .image }.map(\.id)
        let fileIDs = refs.filter { $0.kind == .file }.map(\.id)
        var found: [BlobRef: Data] = [:]
        if !imageIDs.isEmpty {
            for image in try context.fetch(FetchDescriptor<ImageAsset>(predicate: #Predicate { imageIDs.contains($0.id) })) {
                if let data = image.data { found[BlobRef(kind: .image, id: image.id)] = data }
            }
        }
        if !fileIDs.isEmpty {
            for file in try context.fetch(FetchDescriptor<FileAsset>(predicate: #Predicate { fileIDs.contains($0.id) })) {
                if let data = file.data { found[BlobRef(kind: .file, id: file.id)] = data }
            }
        }
        return found
    }

    /// Ids only, in batches: no thought is loaded and the image bytes stay in external storage.
    func allRefs(limit: Int) throws -> [BlobRef]? {
        let context = ModelContext(modelContainer)
        let imageCount = try context.fetchCount(FetchDescriptor<ImageAsset>())
        let fileCount = try context.fetchCount(FetchDescriptor<FileAsset>())
        guard imageCount + fileCount <= limit else { return nil }
        var refs: [BlobRef] = []
        refs.reserveCapacity(imageCount + fileCount)
        var images = FetchDescriptor<ImageAsset>()
        images.propertiesToFetch = [\.id]
        try context.enumerate(images, batchSize: Self.refBatchSize) { refs.append(BlobRef(kind: .image, id: $0.id)) }
        var files = FetchDescriptor<FileAsset>()
        files.propertiesToFetch = [\.id]
        try context.enumerate(files, batchSize: Self.refBatchSize) { refs.append(BlobRef(kind: .file, id: $0.id)) }
        return refs
    }

    private static let refBatchSize = 2000
}

@MainActor
final class ThoughtSyncLocal: SyncLocalStore {
    private let store: ThoughtStore
    private let reconciler: @Sendable () async -> Void
    private nonisolated let container: ModelContainer

    private static let logger = Logger(subsystem: "com.thoughtreps", category: "sync")

    init(store: ThoughtStore, reconcile: @escaping @Sendable () async -> Void) {
        self.store = store
        self.reconciler = reconcile
        container = store.context.container
    }

    private var context: ModelContext { store.context }

    func snapshots(of entities: [SyncEntity]) async throws -> [SyncSnapshot] {
        let thoughtIDs = entities.filter { $0.kind == .thought }.compactMap { UUID(uuidString: $0.id) }
        let tagNames = entities.filter { $0.kind == .tag }.map(\.id)

        var thoughts: [UUID: Thought] = [:]
        var tombstones: [UUID: Tombstone] = [:]
        var tags: [String: Tag] = [:]
        if !thoughtIDs.isEmpty {
            var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { thoughtIDs.contains($0.id) })
            descriptor.relationshipKeyPathsForPrefetching = [\.blocks, \.images, \.files]
            thoughts = Dictionary(try context.fetch(descriptor).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let kind = TombstoneKind.thought.rawValue
            tombstones = Dictionary(
                try context.fetch(FetchDescriptor<Tombstone>(predicate: #Predicate { thoughtIDs.contains($0.id) && $0.kind == kind })).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        if !tagNames.isEmpty {
            tags = Dictionary(
                try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { tagNames.contains($0.name) })).map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        return entities.map { entity in
            switch entity.kind {
            case .thought:
                guard let id = UUID(uuidString: entity.id) else { return SyncSnapshot(entity: entity, payloads: []) }
                if let thought = thoughts[id] {
                    let content = ThoughtContentRecord(thought)
                    let blobs = (content.images + content.blocks.flatMap(\.images)).map { BlobRef(kind: .image, id: $0.id) }
                        + content.blocks.compactMap(\.file).map { BlobRef(kind: .file, id: $0.id) }
                    return SyncSnapshot(
                        entity: entity, payloads: [.thoughtContent(content), .thoughtMeta(ThoughtMetaRecord(thought))], blobs: blobs
                    )
                }
                if let tombstone = tombstones[id] {
                    let deletion = SyncDeletion(id: id, deletedAt: tombstone.deletedAt)
                    return SyncSnapshot(entity: entity, payloads: [.deletion(.thoughtContent, deletion), .deletion(.thoughtMeta, deletion)])
                }
                return SyncSnapshot(entity: entity, payloads: [])
            case .tag:
                guard let tag = tags[entity.id] else { return SyncSnapshot(entity: entity, payloads: []) }
                let record = TagRecord(name: tag.name, displayName: tag.displayName, colorHex: tag.colorHex, updatedAt: tag.updatedAt)
                return SyncSnapshot(entity: entity, payloads: [.tag(record)])
            case .settings:
                return SyncSnapshot(entity: entity, payloads: [.settings(SettingsRecord.current(defaults: store.syncDefaults))])
            }
        }
    }

    nonisolated func blobBytes(_ refs: [BlobRef]) async throws -> [BlobRef: Data] {
        let container = container
        // Built in a detached task so the actor's context isn't created on the main thread.
        return try await Task.detached { try await SyncBlobReader(modelContainer: container).bytes(for: refs) }.value
    }

    nonisolated func allBlobRefs(limit: Int) async throws -> [BlobRef]? {
        let container = container
        return try await Task.detached { try await SyncBlobReader(modelContainer: container).allRefs(limit: limit) }.value
    }

    func missingBlobs(for contents: [ThoughtContentRecord]) async throws -> Set<BlobRef> {
        var wanted = Set<BlobRef>()
        for content in contents {
            for image in content.images + content.blocks.flatMap(\.images) { wanted.insert(BlobRef(kind: .image, id: image.id)) }
            for file in content.blocks.compactMap(\.file) { wanted.insert(BlobRef(kind: .file, id: file.id)) }
        }
        let imageIDs = wanted.filter { $0.kind == .image }.map(\.id)
        let fileIDs = wanted.filter { $0.kind == .file }.map(\.id)
        if !imageIDs.isEmpty {
            for image in try context.fetch(FetchDescriptor<ImageAsset>(predicate: #Predicate { imageIDs.contains($0.id) })) where image.data != nil {
                wanted.remove(BlobRef(kind: .image, id: image.id))
            }
        }
        if !fileIDs.isEmpty {
            for file in try context.fetch(FetchDescriptor<FileAsset>(predicate: #Predicate { fileIDs.contains($0.id) })) where file.data != nil {
                wanted.remove(BlobRef(kind: .file, id: file.id))
            }
        }
        return wanted
    }

    func apply(_ batch: RemoteBatch, now: Date) async -> RemoteOutcome {
        store.applyRemote(batch, now: now)
    }

    func reconcile() async {
        await reconciler()
    }
}
