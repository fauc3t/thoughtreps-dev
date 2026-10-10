import CryptoKit
import Foundation
import SwiftData
import ZIPFoundation

/// Writes every thought, tag and image to a `.thoughtreps` file (see `BackupFormat`).
///
/// Memory stays flat however much is stored: thoughts are read in batches (each batch in a fresh
/// `ModelContext`, so its objects are released) and streamed to a temporary file, and images are read and added
/// to the archive a few at a time. Call `export` off the main actor.
struct BackupExporter: Sendable {
    let container: ModelContainer
    var appVersion: String
    var build: String
    var thoughtBatchSize = 500
    var imageBatchSize = 25

    /// Returns the finished file, inside a fresh temporary directory the caller removes after use.
    /// `progress` runs on the calling thread with a fraction from 0 to 1.
    func export(now: Date, progress: @Sendable (Double) -> Void = { _ in }) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("\(BackupFormat.exportDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            return try build(in: directory, now: now, progress: progress)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private func build(in directory: URL, now: Date, progress: @Sendable (Double) -> Void) throws -> URL {
        let encoder = BackupFormat.encoder()
        var entries: [String: String] = [:]

        let imageHashes = try hashImages { progress(0.25 * $0) }

        let tagsURL = directory.appendingPathComponent(BackupFormat.tagsPath)
        let tagLines = try JSONLWriter(url: tagsURL, encoder: encoder)
        try forEachBatch(of: Tag.self, sortedBy: [SortDescriptor(\.name)], size: thoughtBatchSize) { tags in
            for tag in tags {
                try tagLines.append(TagRecord(name: tag.name, displayName: tag.displayName, colorHex: tag.colorHex, updatedAt: tag.updatedAt))
            }
        }
        entries[BackupFormat.tagsPath] = try tagLines.finish()

        let thoughtsURL = directory.appendingPathComponent(BackupFormat.thoughtsPath)
        let thoughtLines = try JSONLWriter(url: thoughtsURL, encoder: encoder)
        var referenced: [UUID] = []
        var seen = Set<UUID>()
        let total = max(1, try ModelContext(container).fetchCount(FetchDescriptor<Thought>()))
        try forEachThoughtBatch { thoughts in
            for thought in thoughts {
                let record = ThoughtRecord(thought, hasImage: { imageHashes[$0] != nil })
                for id in record.imageIDs where seen.insert(id).inserted {
                    referenced.append(id)
                }
                try thoughtLines.append(record)
            }
            progress(0.25 + 0.25 * Double(thoughtLines.count) / Double(total))
        }
        entries[BackupFormat.thoughtsPath] = try thoughtLines.finish()
        for id in referenced {
            entries[BackupFormat.imagePath(for: id)] = imageHashes[id]
        }

        let manifest = BackupManifest(
            format: BackupFormat.identifier, formatVersion: BackupFormat.currentVersion,
            appVersion: appVersion, build: build, exportedAt: now,
            counts: .init(thoughts: thoughtLines.count, tags: tagLines.count, images: referenced.count),
            entries: entries
        )

        let archiveURL = directory.appendingPathComponent(BackupFormat.fileName(for: now))
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try add(Data(BackupFormat.mimeType.utf8), as: BackupFormat.mimetypePath, to: archive, method: .none)
        try add(try encoder.encode(manifest), as: BackupFormat.manifestPath, to: archive, method: .deflate)
        try archive.addEntry(with: BackupFormat.tagsPath, fileURL: tagsURL, compressionMethod: .deflate)
        try archive.addEntry(with: BackupFormat.thoughtsPath, fileURL: thoughtsURL, compressionMethod: .deflate)
        try FileManager.default.removeItem(at: tagsURL)
        try FileManager.default.removeItem(at: thoughtsURL)

        var added = 0
        for ids in referenced.chunked(into: imageBatchSize) {
            try autoreleasepool {
                let context = ModelContext(container)
                let images = try context.fetch(FetchDescriptor<ImageAsset>(predicate: #Predicate { ids.contains($0.id) }))
                let byID = Dictionary(images.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for id in ids {
                    guard let data = byID[id]?.data, hash(of: data) == imageHashes[id] else {
                        throw BackupError.changedDuringExport
                    }
                    try add(data, as: BackupFormat.imagePath(for: id), to: archive, method: .none)
                }
            }
            added += ids.count
            progress(0.5 + 0.5 * Double(added) / Double(max(1, referenced.count)))
        }
        return archiveURL
    }

    /// SHA-256 of every image's bytes, read in batches. Needed before the archive is written because
    /// the manifest, which lists the hashes, comes second.
    private func hashImages(progress: (Double) -> Void) throws -> [UUID: String] {
        var hashes: [UUID: String] = [:]
        let total = max(1, try ModelContext(container).fetchCount(FetchDescriptor<ImageAsset>()))
        try forEachImageBatch { images in
            for image in images {
                if let data = image.data {
                    hashes[image.id] = hash(of: data)
                }
            }
            progress(Double(hashes.count) / Double(total))
        }
        return hashes
    }

    private func hash(of data: Data) -> String {
        BackupFormat.hex(of: SHA256.hash(data: data))
    }

    private func add(_ data: Data, as path: String, to archive: Archive, method: CompressionMethod) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: method) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }

    /// Thoughts in `createdAt`, `id` order, each batch fetched in its own context starting after the last
    /// thought of the previous one, so thoughts deleted or edited meanwhile can't shift later ones out of the run.
    private func forEachThoughtBatch(_ body: ([Thought]) throws -> Void) throws {
        var last: (createdAt: Date, id: UUID)?
        while true {
            let count: Int = try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                var descriptor = FetchDescriptor<Thought>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.id)])
                if let last {
                    let (date, id) = last
                    descriptor.predicate = #Predicate { $0.createdAt > date || ($0.createdAt == date && $0.id > id) }
                }
                descriptor.fetchLimit = thoughtBatchSize
                descriptor.relationshipKeyPathsForPrefetching = [\.tags, \.blocks, \.images]
                let thoughts = try context.fetch(descriptor)
                try body(thoughts)
                if let end = thoughts.last { last = (end.createdAt, end.id) }
                return thoughts.count
            }
            if count < thoughtBatchSize { return }
        }
    }

    private func forEachImageBatch(_ body: ([ImageAsset]) throws -> Void) throws {
        var last: UUID?
        while true {
            let count: Int = try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                var descriptor = FetchDescriptor<ImageAsset>(sortBy: [SortDescriptor(\.id)])
                if let last {
                    descriptor.predicate = #Predicate { $0.id > last }
                }
                descriptor.fetchLimit = imageBatchSize
                let images = try context.fetch(descriptor)
                try body(images)
                if let end = images.last { last = end.id }
                return images.count
            }
            if count < imageBatchSize { return }
        }
    }

    /// Tags are few, so plain offset paging is enough.
    private func forEachBatch<Model: PersistentModel>(
        of _: Model.Type, sortedBy sort: [SortDescriptor<Model>], size: Int, _ body: ([Model]) throws -> Void
    ) throws {
        var offset = 0
        while true {
            let count: Int = try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                var descriptor = FetchDescriptor<Model>(sortBy: sort)
                descriptor.fetchLimit = size
                descriptor.fetchOffset = offset
                let models = try context.fetch(descriptor)
                try body(models)
                return models.count
            }
            offset += count
            if count < size { return }
        }
    }
}

extension ThoughtRecord {
    init(_ thought: Thought, hasImage: (UUID) -> Bool) {
        func record(_ image: ImageAsset) -> ImageRecord {
            ImageRecord(id: image.id, width: image.width, height: image.height, order: image.order)
        }
        // An inline image with no bytes isn't exported, so its token would dangle.
        let missing = (thought.images ?? []).filter { $0.block == nil && !hasImage($0.id) }
        func stripped(_ text: String) -> String {
            missing.reduce(text) { $0.replacingOccurrences(of: ImageToken.token(for: $1.id), with: "") }
        }
        let body = stripped(thought.body)
        self.init(
            id: thought.id, body: body, createdAt: thought.createdAt, updatedAt: thought.updatedAt,
            scheduleChangedAt: thought.scheduleChangedAt, stateChangedAt: thought.stateChangedAt,
            nextDueAt: thought.nextDueAt, lastViewedAt: thought.lastViewedAt, viewCount: thought.viewCount,
            intervalDays: thought.intervalDays, intervalModeRaw: thought.intervalModeRaw,
            learnIntervalDays: thought.learnIntervalDays,
            isPinned: thought.isPinned, isArchived: thought.isArchived, archivedAt: thought.archivedAt,
            tags: thought.sortedTags.map(\.name),
            blocks: thought.sortedBlocks.compactMap { block in
                let isMarkdown = block.kind == .markdown
                let content = isMarkdown ? stripped(block.content) : block.content
                if isMarkdown, content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                return BlockRecord(
                    id: block.id, kindRaw: block.kind.rawValue, title: block.title, content: content, order: block.order,
                    isBlurred: block.kind == .markdown && (block.isBlurred || block.kindRaw == BlockKind.legacyBlurredRaw),
                    images: block.sortedImages.filter { hasImage($0.id) }.map(record)
                )
            },
            images: (thought.images ?? []).filter { $0.block == nil && hasImage($0.id) }
                .sorted { ($0.order, $0.id.uuidString) < ($1.order, $1.id.uuidString) }.map(record)
        )
    }
}

/// Appends one JSON value per line to a file, hashing the bytes as they go.
private final class JSONLWriter {
    private let handle: FileHandle
    private let encoder: JSONEncoder
    private var hasher = SHA256()
    private(set) var count = 0

    init(url: URL, encoder: JSONEncoder) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.encoder = encoder
    }

    func append(_ value: some Encodable) throws {
        var line = try encoder.encode(value)
        line.append(0x0A)
        try handle.write(contentsOf: line)
        hasher.update(data: line)
        count += 1
    }

    func finish() throws -> String {
        try handle.close()
        return BackupFormat.hex(of: hasher.finalize())
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
