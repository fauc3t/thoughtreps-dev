import CryptoKit
import Foundation
import os
import SwiftData
import ZIPFoundation

/// What a zip bomb or hostile archive is held to. Entries are read into memory or hashed as they
/// stream, never extracted to disk.
struct ImportLimits: Sendable {
    var manifestBytes = 64 << 20
    var tagsBytes = 16 << 20
    var thoughtsBytes = 16 << 30
    var imageBytes = 64 << 20
    /// One line of `thoughts.jsonl`.
    var lineBytes = 8 << 20
    var entryCount = 2_000_000
    /// A batch is cut once its images (originals plus thumbnails) reach this many bytes, even before it has `batchSize` thoughts.
    var batchImageBytes = 48 << 20

    static let standard = ImportLimits()

    func limit(for path: String) -> Int? {
        switch path {
        case BackupFormat.mimetypePath: BackupFormat.mimeType.utf8.count
        case BackupFormat.manifestPath: manifestBytes
        case BackupFormat.tagsPath: tagsBytes
        case BackupFormat.thoughtsPath: thoughtsBytes
        default: BackupFormat.imageID(inPath: path) == nil ? nil : imageBytes
        }
    }
}

/// What reading the whole file once (signature, manifest, every hash, every thought) found.
struct BackupPreflight: Sendable {
    let fileURL: URL
    let manifest: BackupManifest
    let tags: [TagRecord]
    /// The `updatedAt` of every importable thought, by id (the newest, if an id repeats).
    let stamps: [UUID: Date]
    /// Thought lines that decode but break a store invariant, so can't be imported.
    let unimportable: Int
}

/// How the file compares with what is stored, which is what the summary sheet shows.
struct BackupPlan: Sendable {
    let preflight: BackupPreflight
    /// Thoughts to write: those not stored, and those stored with an older `updatedAt`.
    let toImport: Set<UUID>
    let new: Int
    let newer: Int
    let upToDate: Int

    var thoughtCount: Int { preflight.manifest.counts.thoughts }
    var imageCount: Int { preflight.manifest.counts.images }
}

enum BackupImporter {
    static let batchSize = 200

    // MARK: Preflight

    /// Checks the file end to end without writing anything. Blocks while reading, so call it off the main actor.
    static func preflight(fileURL: URL, limits: ImportLimits = .standard) throws -> BackupPreflight {
        guard try hasSignature(fileURL) else { throw BackupError.notAnExport }
        let archive = try openArchive(fileURL)
        let entries = try catalog(archive, limits: limits)
        guard entries[BackupFormat.mimetypePath] != nil, let manifestEntry = entries[BackupFormat.manifestPath] else {
            throw BackupError.notAnExport
        }

        let manifestData = try read(manifestEntry, of: archive, limit: limits.manifestBytes)
        struct Header: Decodable {
            var format: String
            var formatVersion: Int
        }
        let decoder = BackupFormat.decoder()
        guard let header = try? decoder.decode(Header.self, from: manifestData), header.format == BackupFormat.identifier else {
            throw BackupError.notAnExport
        }
        guard header.formatVersion <= BackupFormat.currentVersion else { throw BackupError.needsNewerApp }
        guard header.formatVersion == BackupFormat.currentVersion else { throw BackupError.damaged("unknown version") }
        guard let manifest = try? decoder.decode(BackupManifest.self, from: manifestData) else {
            throw BackupError.damaged("unreadable manifest")
        }

        let listed = Set(manifest.entries.keys)
        guard listed == Set(entries.keys).subtracting([BackupFormat.mimetypePath, BackupFormat.manifestPath]) else {
            throw BackupError.damaged("the manifest doesn't match the file's contents")
        }
        let imageCount = listed.filter { BackupFormat.imageID(inPath: $0) != nil }.count
        guard manifest.counts.images == imageCount else { throw BackupError.damaged("image count") }

        var tags: [TagRecord] = []
        var stamps: [UUID: Date] = [:]
        var thoughtLines = 0
        var unimportable = 0
        func readTag(_ line: Data) throws {
            tags.append(try decode(TagRecord.self, line, decoder))
        }
        func readThought(_ line: Data) throws {
            thoughtLines += 1
            let record = try decode(ThoughtRecord.self, line, decoder)
            if record.isImportable, record.imageIDs.allSatisfy({ listed.contains(BackupFormat.imagePath(for: $0)) }) {
                stamps[record.id] = max(stamps[record.id] ?? .distantPast, record.updatedAt)
            } else {
                unimportable += 1
            }
        }
        for (path, expected) in manifest.entries.sorted(by: { $0.key < $1.key }) {
            guard let entry = entries[path], let limit = limits.limit(for: path) else { throw BackupError.unsafe(path) }
            var hasher = SHA256()
            var lines = LineReader(maxLineBytes: limits.lineBytes)
            let readLine: ((Data) throws -> Void)? = switch path {
            case BackupFormat.tagsPath: readTag
            case BackupFormat.thoughtsPath: readThought
            default: nil
            }
            try stream(entry, of: archive, limit: limit) { chunk in
                hasher.update(data: chunk)
                if let readLine { try lines.feed(chunk, readLine) }
            }
            if let readLine { try lines.finish(readLine) }
            guard BackupFormat.hex(of: hasher.finalize()) == expected else { throw BackupError.damaged("\(path) is corrupt") }
        }
        guard thoughtLines == manifest.counts.thoughts, tags.count == manifest.counts.tags else {
            throw BackupError.damaged("record counts")
        }
        return BackupPreflight(fileURL: fileURL, manifest: manifest, tags: tags, stamps: stamps, unimportable: unimportable)
    }

    /// The `mimetype` entry sits first, uncompressed and with no extra field, so these bytes are fixed.
    static func hasSignature(_ url: URL) throws -> Bool {
        let expected = Array(BackupFormat.mimeType.utf8)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = Array(try handle.read(upToCount: BackupFormat.signatureOffset + expected.count) ?? Data())
        guard head.count == BackupFormat.signatureOffset + expected.count else { return false }
        let localHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let name = Array(BackupFormat.mimetypePath.utf8)
        return head[0..<4] == localHeader[...]
            && head[8] == 0 && head[9] == 0 // stored
            && head[26] == UInt8(name.count) && head[27] == 0
            && head[28] == 0 && head[29] == 0 // no extra field
            && head[30..<30 + name.count] == name[...]
            && head[BackupFormat.signatureOffset...] == expected[...]
    }

    private static func openArchive(_ url: URL) throws -> Archive {
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw BackupError.damaged("the zip can't be read")
        }
    }

    /// Every entry by path. Rejects paths outside the format (which covers `..` and absolute
    /// paths), repeated paths, anything but plain files, and sizes over the limits.
    private static func catalog(_ archive: Archive, limits: ImportLimits) throws -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for entry in archive {
            guard entries.count < limits.entryCount else { throw BackupError.unsafe("too many entries") }
            guard let limit = limits.limit(for: entry.path) else {
                throw BackupError.unsafe("unexpected entry \(entry.path.prefix(80))")
            }
            guard entry.type == .file, entries.updateValue(entry, forKey: entry.path) == nil else {
                throw BackupError.unsafe("entry \(entry.path.prefix(80)) is repeated or not a file")
            }
            guard entry.uncompressedSize <= UInt64(limit) else { throw BackupError.unsafe("\(entry.path) is too large") }
        }
        return entries
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ line: Data, _ decoder: JSONDecoder) throws -> Value {
        do {
            return try decoder.decode(type, from: line)
        } catch {
            throw BackupError.damaged("unreadable \(Value.self)")
        }
    }

    // MARK: Reading entries

    /// Feeds the entry to `consume` in chunks, refusing more than `limit` bytes however much the
    /// zip header claims.
    static func stream(_ entry: Entry, of archive: Archive, limit: Int, _ consume: (Data) throws -> Void) throws {
        var total = 0
        do {
            _ = try archive.extract(entry) { chunk in
                total += chunk.count
                guard total <= limit else { throw BackupError.unsafe("\(entry.path.prefix(80)) is too large") }
                try consume(chunk)
            }
        } catch let error as BackupError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BackupError.damaged("\(entry.path.prefix(80)) can't be read")
        }
    }

    static func read(_ entry: Entry, of archive: Archive, limit: Int) throws -> Data {
        var data = Data()
        try stream(entry, of: archive, limit: limit) { data.append($0) }
        return data
    }

    // MARK: Plan

    /// Compares the file with the store, in batches of ids, loading only `id` and `updatedAt`.
    static func plan(_ preflight: BackupPreflight, container: ModelContainer) throws -> BackupPlan {
        var toImport = Set<UUID>()
        var new = 0
        var newer = 0
        var upToDate = 0
        for ids in Array(preflight.stamps.keys).chunked(into: 400) {
            try autoreleasepool {
                let context = ModelContext(container)
                var descriptor = FetchDescriptor<Thought>(predicate: #Predicate { ids.contains($0.id) })
                descriptor.propertiesToFetch = [\.id, \.updatedAt]
                let stored = Dictionary(
                    try context.fetch(descriptor).map { ($0.id, $0.updatedAt) },
                    uniquingKeysWith: { first, _ in first }
                )
                for id in ids {
                    guard let incoming = preflight.stamps[id] else { continue }
                    if let current = stored[id] {
                        if incoming > current {
                            newer += 1
                            toImport.insert(id)
                        } else {
                            upToDate += 1
                        }
                    } else {
                        new += 1
                        toImport.insert(id)
                    }
                }
            }
        }
        return BackupPlan(preflight: preflight, toImport: toImport, new: new, newer: newer, upToDate: upToDate)
    }

    // MARK: Batches

    struct Batch: Sendable {
        var thoughts: [ImportedThought]
        /// Thoughts of this batch left out because an image couldn't be read.
        var unreadable: Int
    }

    /// Reads the thoughts to import in batches, with their images and regenerated thumbnails. The
    /// reader stays at most one batch ahead of the caller, so memory stays bounded. Stops if the
    /// caller stops iterating.
    static func batches(for plan: BackupPlan, limits: ImportLimits = .standard) -> BatchSequence {
        let requested = DispatchSemaphore(value: 0)
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let stream = AsyncThrowingStream<Batch, Error> { continuation in
            continuation.onTermination = { _ in
                stopped.withLock { $0 = true }
                requested.signal()
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try readBatches(plan, limits: limits) { batch in
                        continuation.yield(batch)
                        requested.wait()
                        if stopped.withLock({ $0 }) { throw CancellationError() }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return BatchSequence(stream: stream, requested: requested)
    }

    /// Asking for the next batch tells the reader the previous one is taken.
    struct BatchSequence: AsyncSequence {
        let stream: AsyncThrowingStream<Batch, Error>
        let requested: DispatchSemaphore

        struct AsyncIterator: AsyncIteratorProtocol {
            var base: AsyncThrowingStream<Batch, Error>.AsyncIterator
            let requested: DispatchSemaphore

            mutating func next() async throws -> Batch? {
                requested.signal()
                return try await base.next()
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: stream.makeAsyncIterator(), requested: requested)
        }
    }

    private static func readBatches(_ plan: BackupPlan, limits: ImportLimits, deliver: (Batch) throws -> Void) throws {
        let url = plan.preflight.fileURL
        let thoughtsArchive = try openArchive(url)
        let imagesArchive = try openArchive(url)
        let entries = try catalog(thoughtsArchive, limits: limits)
        let imageEntries = try catalog(imagesArchive, limits: limits)
        guard let thoughtsEntry = entries[BackupFormat.thoughtsPath] else { throw BackupError.damaged("no thoughts") }
        let decoder = BackupFormat.decoder()
        var lines = LineReader(maxLineBytes: limits.lineBytes)
        var delivered = Set<UUID>()

        var batch = Batch(thoughts: [], unreadable: 0)
        var batchBytes = 0

        func flush() throws {
            guard !batch.thoughts.isEmpty || batch.unreadable > 0 else { return }
            let full = batch
            batch = Batch(thoughts: [], unreadable: 0)
            batchBytes = 0
            try deliver(full)
        }

        func accept(_ line: Data) throws {
            let record = try decode(ThoughtRecord.self, line, decoder)
            guard plan.toImport.contains(record.id), plan.preflight.stamps[record.id] == record.updatedAt, record.isImportable,
                  delivered.insert(record.id).inserted
            else { return }
            do {
                var images: [UUID: ProcessedImage] = [:]
                var bytes = 0
                for ref in record.images + record.blocks.flatMap(\.images) {
                    guard let entry = imageEntries[BackupFormat.imagePath(for: ref.id)] else { throw BackupError.damaged("missing image") }
                    let data = try read(entry, of: imagesArchive, limit: limits.imageBytes)
                    let processed = try ImageProcessor.importable(data)
                    bytes += processed.data.count + processed.thumbnailData.count
                    images[ref.id] = processed
                }
                batch.thoughts.append(ImportedThought(record: record, images: images))
                batchBytes += bytes
            } catch is ImageProcessingError {
                batch.unreadable += 1
            }
            if batch.thoughts.count + batch.unreadable >= batchSize || batchBytes >= limits.batchImageBytes { try flush() }
        }

        try stream(thoughtsEntry, of: thoughtsArchive, limit: limits.thoughtsBytes) { chunk in
            try lines.feed(chunk, accept)
        }
        try lines.finish(accept)
        try flush()
    }
}

/// A thought read from the file, with its images ready to store (original bytes plus a regenerated thumbnail).
struct ImportedThought: Sendable {
    let record: ThoughtRecord
    let images: [UUID: ProcessedImage]
}

/// What `ThoughtStore.importThoughts` did, summed over batches.
struct ImportTally: Equatable {
    var added = 0
    var replaced = 0
    var upToDate = 0
    /// Thoughts left out because their images clash with another thought's.
    var rejected = 0
}

/// Splits streamed bytes into lines, refusing a line longer than `maxLineBytes`.
struct LineReader {
    let maxLineBytes: Int
    private var buffer = Data()

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    mutating func feed(_ chunk: Data, _ line: (Data) throws -> Void) throws {
        buffer.append(chunk)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            if newline > start { try line(buffer[start..<newline]) }
            start = newline + 1
        }
        buffer = Data(buffer[start...])
        guard buffer.count <= maxLineBytes else { throw BackupError.unsafe("a line is too long") }
    }

    mutating func finish(_ line: (Data) throws -> Void) throws {
        if !buffer.isEmpty { try line(buffer) }
        buffer = Data()
    }
}
