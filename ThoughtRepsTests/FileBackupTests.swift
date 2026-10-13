import Foundation
import SwiftData
import Testing
import ZIPFoundation
@testable import ThoughtReps

@MainActor
@Suite("File blocks in export and import")
struct FileBackupTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let source: ModelContainer
    let destination: ModelContainer
    let sourceStore: ThoughtStore
    let destinationStore: ThoughtStore
    let directory: URL
    let isolated = IsolatedDefaults()

    init() throws {
        source = try ModelContainer.thoughtReps(inMemory: true)
        destination = try ModelContainer.thoughtReps(inMemory: true)
        sourceStore = ThoughtStore(
            context: source.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: isolated.pendingImageSaves
        )
        destinationStore = ThoughtStore(
            context: destination.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter(),
            pendingImageSaves: isolated.pendingImageSaves
        )
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileBackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func export() throws -> URL {
        try BackupExporter(container: source, appVersion: "1.0", build: "7").export(now: now)
    }

    @discardableResult
    func importFile(_ url: URL, limits: ImportLimits = .standard) async throws -> (plan: BackupPlan, tally: ImportTally, unreadable: Int) {
        let preflight = try BackupImporter.preflight(fileURL: url, limits: limits)
        let plan = try BackupImporter.plan(preflight, container: destination)
        var tally = ImportTally()
        var unreadable = 0
        for try await batch in BackupImporter.batches(for: plan, limits: limits) {
            unreadable += batch.unreadable
            #expect(destinationStore.importThoughts(batch.thoughts, tags: preflight.tags, tally: &tally))
        }
        return (plan, tally, unreadable)
    }

    func stored(_ id: UUID, in container: ModelContainer) throws -> Thought? {
        try container.mainContext.fetch(FetchDescriptor<Thought>(predicate: #Predicate { $0.id == id })).first
    }

    func expectClean(_ container: ModelContainer) throws {
        #expect(try IntegrityChecker.check(container.mainContext).map(\.description) == [])
    }

    /// An archive holding `records` and `files`, with a manifest that matches them unless `fileHashes` overrides.
    func makeArchive(records: [ThoughtRecord], files: [UUID: Data], listing listed: Set<UUID>? = nil, to url: URL) throws {
        let encoder = BackupFormat.encoder()
        var thoughts = Data()
        for record in records {
            thoughts.append(try encoder.encode(record))
            thoughts.append(0x0A)
        }
        let tags = Data()
        var hashes = [BackupFormat.tagsPath: sha256Hex(tags), BackupFormat.thoughtsPath: sha256Hex(thoughts)]
        for (id, data) in files { hashes[BackupFormat.filePath(for: id)] = sha256Hex(data) }
        let manifest = BackupManifest(
            format: BackupFormat.identifier, formatVersion: BackupFormat.currentVersion, appVersion: "1", build: "1", exportedAt: now,
            counts: .init(thoughts: records.count, tags: 0, images: 0, files: files.count), entries: hashes
        )
        var entries = [
            ArchiveEntry(path: "mimetype", data: Data(BackupFormat.mimeType.utf8), method: .none),
            ArchiveEntry(path: "manifest.json", data: try encoder.encode(manifest)),
            ArchiveEntry(path: BackupFormat.tagsPath, data: tags, method: .none),
            ArchiveEntry(path: BackupFormat.thoughtsPath, data: thoughts, method: .none),
        ]
        for (id, data) in files where listed?.contains(id) ?? true {
            entries.append(ArchiveEntry(path: BackupFormat.filePath(for: id), data: data))
        }
        try writeArchive(entries, to: url)
    }

    func fileRecord(_ id: UUID = UUID(), name: String = "doc.pdf", byteCount: Int) -> (block: BlockRecord, file: FileRecord) {
        let file = FileRecord(id: id, filename: name, typeIdentifier: "com.adobe.pdf", byteCount: byteCount)
        return (BlockRecord(id: UUID(), kindRaw: BlockKind.file.rawValue, title: nil, content: "", order: 0, images: [], file: file), file)
    }

    // MARK: Round trip

    @Test func fileBlocksRoundTrip() async throws {
        let first = fakeFile(1, name: "one.pdf")
        let second = fakeFile(2, name: "two.csv", type: "public.comma-separated-values-text")
        let original = sourceStore.create(
            body: "# Files", blocks: [fileBlock(first), BlockDraft(content: "between"), fileBlock(second)], now: now
        )
        let plain = sourceStore.create(body: "# Plain", now: now.addingTimeInterval(1))
        let url = try export()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let preflight = try BackupImporter.preflight(fileURL: url)
        #expect(preflight.manifest.counts.files == 2)
        #expect(preflight.manifest.entries.keys.contains(BackupFormat.filePath(for: first.id)))
        #expect(preflight.unimportable == 0)

        let result = try await importFile(url)
        #expect(result.tally.added == 2)
        #expect(result.unreadable == 0)
        let copy = try #require(try stored(original.id, in: destination))
        #expect(copy.sortedBlocks.map(\.kind) == [.file, .markdown, .file])
        let files = copy.sortedBlocks.compactMap(\.file)
        #expect(files.map(\.id) == [first.id, second.id])
        #expect(files.map(\.filename) == ["one.pdf", "two.csv"])
        #expect(files.map(\.typeIdentifier) == ["com.adobe.pdf", "public.comma-separated-values-text"])
        #expect(files.map(\.data) == [first.data, second.data])
        #expect(files.map(\.byteCount) == [3, 3])
        #expect(try stored(plain.id, in: destination)?.blocks?.isEmpty == true)
        try expectClean(destination)
    }

    @Test func importingTheSameFileTwiceChangesNothing() async throws {
        sourceStore.create(body: "# Files", blocks: [fileBlock(fakeFile(1))], now: now)
        let url = try export()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await importFile(url)
        let again = try await importFile(url)
        #expect(again.plan.toImport.isEmpty)
        #expect(try destination.mainContext.fetchCount(FetchDescriptor<FileAsset>()) == 1)
        try expectClean(destination)
    }

    @Test func newerFileContentMergesByUpdatedAt() async throws {
        let thought = sourceStore.create(body: "# Files", blocks: [fileBlock(fakeFile(1, name: "one.pdf"))], now: now)
        let url = try export()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await importFile(url)

        sourceStore.update(
            thought, body: "# Files", blocks: BlockDraft.drafts(for: thought) + [fileBlock(fakeFile(2, name: "two.pdf"))],
            intervalDays: nil, now: now.addingTimeInterval(60)
        )
        let newer = try export()
        defer { try? FileManager.default.removeItem(at: newer.deletingLastPathComponent()) }
        let merged = try await importFile(newer)
        #expect(merged.tally.replaced == 1)
        let copy = try #require(try stored(thought.id, in: destination))
        #expect(copy.sortedBlocks.compactMap(\.file).map(\.filename) == ["one.pdf", "two.pdf"])
        try expectClean(destination)

        // The older export no longer wins: the destination keeps both files.
        try await importFile(url)
        #expect(copy.sortedBlocks.compactMap(\.file).count == 2)

        // A newer export without the file removes it.
        sourceStore.update(thought, body: "# Files", blocks: [], intervalDays: nil, now: now.addingTimeInterval(120))
        let removed = try export()
        defer { try? FileManager.default.removeItem(at: removed.deletingLastPathComponent()) }
        try await importFile(removed)
        #expect(copy.blocks?.isEmpty == true)
        #expect(try destination.mainContext.fetchCount(FetchDescriptor<FileAsset>()) == 0)
        try expectClean(destination)
    }

    // MARK: Refusals

    @Test func tamperedFileBytesAreRejected() throws {
        let data = Data("pdf".utf8)
        let (block, file) = fileRecord(byteCount: data.count)
        let url = directory.appendingPathComponent("tampered.thoughtreps")
        try makeArchive(records: [record(blocks: [block])], files: [file.id: data], to: url)
        _ = try BackupImporter.preflight(fileURL: url)

        let archive = try Archive(url: url, accessMode: .read)
        var entries: [ArchiveEntry] = []
        for entry in archive {
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            if entry.path == BackupFormat.filePath(for: file.id) { bytes = Data("PDF".utf8) }
            entries.append(ArchiveEntry(path: entry.path, data: bytes, method: entry.path == "mimetype" ? .none : .deflate))
        }
        let bad = directory.appendingPathComponent("bad.thoughtreps")
        try writeArchive(entries, to: bad)
        #expect(throws: BackupError.damaged("\(BackupFormat.filePath(for: file.id)) is corrupt")) {
            try BackupImporter.preflight(fileURL: bad)
        }
    }

    @Test func oversizeFileEntryIsRejected() throws {
        let data = Data(count: 100)
        let (block, file) = fileRecord(byteCount: data.count)
        let url = directory.appendingPathComponent("big.thoughtreps")
        try makeArchive(records: [record(blocks: [block])], files: [file.id: data], to: url)
        var limits = ImportLimits.standard
        limits.fileBytes = 99
        do {
            _ = try BackupImporter.preflight(fileURL: url, limits: limits)
            Issue.record("Expected rejection")
        } catch let error as BackupError {
            guard case .unsafe = error else {
                Issue.record("Expected .unsafe, got \(error)")
                return
            }
        }
        #expect(ImportLimits.standard.fileBytes > FileAttachment.maxBytes)
        #expect(ImportLimits.standard.fileBytes < FileAttachment.maxBytes + (1 << 20))
    }

    @Test func fileEntryOverTheRealLimitIsRejected() throws {
        let data = Data(count: ImportLimits.standard.fileBytes + 1)
        let (block, file) = fileRecord(byteCount: FileAttachment.maxBytes)
        let url = directory.appendingPathComponent("huge.thoughtreps")
        try makeArchive(records: [record(blocks: [block])], files: [file.id: data], to: url)
        do {
            _ = try BackupImporter.preflight(fileURL: url)
            Issue.record("Expected rejection")
        } catch let error as BackupError {
            guard case .unsafe = error else {
                Issue.record("Expected .unsafe, got \(error)")
                return
            }
        }
    }

    @Test func recordsWithoutTheirFileBytesAreUnimportable() throws {
        let (block, file) = fileRecord(byteCount: 3)
        let url = directory.appendingPathComponent("missing.thoughtreps")
        try makeArchive(records: [record(blocks: [block])], files: [file.id: Data(count: 3)], listing: [], to: url)
        #expect(throws: BackupError.damaged("the manifest doesn't match the file's contents")) {
            try BackupImporter.preflight(fileURL: url)
        }

        let other = fileRecord(byteCount: 3).block
        let unlisted = directory.appendingPathComponent("unlisted.thoughtreps")
        try makeArchive(records: [record(blocks: [other])], files: [:], to: unlisted)
        #expect(try BackupImporter.preflight(fileURL: unlisted).unimportable == 1)
    }

    @Test func invalidFileRecordsAreUnimportable() throws {
        func importable(_ block: BlockRecord) -> Bool { record(blocks: [block]).isImportable }
        let good = fileRecord(byteCount: 3).block
        #expect(importable(good))

        var tooBig = good
        tooBig.file?.byteCount = FileAttachment.maxBytes + 1
        #expect(!importable(tooBig))
        var negative = good
        negative.file?.byteCount = -1
        #expect(!importable(negative))
        var unnamed = good
        unnamed.file?.filename = ""
        #expect(!importable(unnamed))
        var noFile = good
        noFile.file = nil
        #expect(!importable(noFile))
        var withContent = good
        withContent.content = "x"
        #expect(!importable(withContent))
        var strayFile = BlockRecord(id: UUID(), kindRaw: BlockKind.markdown.rawValue, title: nil, content: "x", order: 0, images: [], file: good.file)
        #expect(!importable(strayFile))
        strayFile.file = nil
        #expect(importable(strayFile))

        let shared = fileRecord(UUID(), byteCount: 3)
        var second = fileRecord(shared.file.id, byteCount: 3).block
        second.order = 1
        #expect(!record(blocks: [shared.block, second]).isImportable)
    }

    @Test func fileWhoseBytesDisagreeWithItsRecordIsLeftOut() async throws {
        let data = Data("pdf".utf8)
        let (block, file) = fileRecord(byteCount: data.count + 5)
        let url = directory.appendingPathComponent("mismatch.thoughtreps")
        try makeArchive(records: [record(blocks: [block])], files: [file.id: data], to: url)
        let result = try await importFile(url)
        #expect(result.unreadable == 1)
        #expect(result.tally.added == 0)
        #expect(try destination.mainContext.fetchCount(FetchDescriptor<Thought>()) == 0)
    }

    @Test func fileAlreadyOwnedByAnotherThoughtIsRejected() async throws {
        let data = Data("pdf".utf8)
        let id = UUID()
        let (block, _) = fileRecord(id, byteCount: data.count)
        let ownerRecord = record(blocks: [block])
        let url = directory.appendingPathComponent("owner.thoughtreps")
        try makeArchive(records: [ownerRecord], files: [id: data], to: url)
        try await importFile(url)

        let (clashing, _) = fileRecord(id, byteCount: data.count)
        let intruder = record(blocks: [clashing])
        let again = directory.appendingPathComponent("intruder.thoughtreps")
        try makeArchive(records: [intruder], files: [id: data], to: again)
        let result = try await importFile(again)
        #expect(result.tally.rejected == 1)
        #expect(try destination.mainContext.fetchCount(FetchDescriptor<FileAsset>()) == 1)
        try expectClean(destination)
    }

    @Test func manifestCountsFromBeforeFilesStillDecode() throws {
        let json = Data(#"{"thoughts":1,"tags":2,"images":3}"#.utf8)
        let counts = try JSONDecoder().decode(BackupManifest.Counts.self, from: json)
        #expect(counts == .init(thoughts: 1, tags: 2, images: 3, files: 0))
    }
}
