import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import os
import SwiftData
import Testing
import UniformTypeIdentifiers
import ZIPFoundation
@testable import ThoughtReps

/// A small real image (the importer decodes images to regenerate thumbnails).
func realImage(_ hue: CGFloat) throws -> ImageDraft {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: hue, green: 1 - hue, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return ImageDraft(processed: try ImageProcessor.process(output as Data))
}

func sha256Hex(_ data: Data) -> String {
    BackupFormat.hex(of: SHA256.hash(data: data))
}

struct ArchiveEntry {
    var path: String
    var data: Data
    var method: CompressionMethod = .deflate
}

func writeArchive(_ entries: [ArchiveEntry], to url: URL) throws {
    let archive = try Archive(url: url, accessMode: .create)
    for entry in entries {
        try archive.addEntry(
            with: entry.path, type: .file, uncompressedSize: Int64(entry.data.count), compressionMethod: entry.method
        ) { position, size in
            entry.data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
}

func record(
    id: UUID = UUID(), body: String = "# Hello", createdAt: Date = Date(timeIntervalSince1970: 1_790_000_000),
    updatedAt: Date? = nil, blocks: [BlockRecord] = [], images: [ImageRecord] = []
) -> ThoughtRecord {
    ThoughtRecord(
        id: id, body: body, createdAt: createdAt, updatedAt: updatedAt ?? createdAt, nextDueAt: createdAt.addingTimeInterval(86_400),
        lastViewedAt: nil, viewCount: 0, intervalDays: nil, intervalModeRaw: IntervalMode.fixed.rawValue,
        isPinned: false, isArchived: false, archivedAt: nil, tags: [], blocks: blocks, images: images
    )
}

@MainActor
@Suite("Export and import")
struct BackupTests {
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
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Helpers

    func populate() throws {
        let inline = try realImage(0.2)
        let one = sourceStore.create(
            body: "# One\n\(ImageToken.token(for: inline.id))\n#swift #Work",
            blocks: [
                BlockDraft(title: "Quiz", content: "Answer"),
                BlockDraft(kind: .gallery, title: "Gallery", images: [try realImage(0.5), try realImage(0.9)]),
            ],
            images: [inline], intervalDays: 3, now: now
        )
        sourceStore.overrideSchedule(one, nextDueAt: now.addingTimeInterval(90_000.5), lastViewedAt: now, viewCount: 2)
        sourceStore.setPinned(one, true)
        let two = sourceStore.create(body: "# Two\n#swift #café", now: now.addingTimeInterval(60))
        sourceStore.archive(two, now: now.addingTimeInterval(120))
        sourceStore.create(body: "# Three, no tags", now: now.addingTimeInterval(180))
        for tag in try source.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()) where tag.name == "work" {
            tag.colorHex = "#FF8800"
        }
        try source.mainContext.save()
    }

    func export(from container: ModelContainer) throws -> URL {
        try BackupExporter(container: container, appVersion: "1.0", build: "7").export(now: now)
    }

    @discardableResult
    func importFile(_ url: URL, store: ThoughtStore? = nil) async throws -> (plan: BackupPlan, tally: ImportTally) {
        let store = store ?? destinationStore
        let preflight = try BackupImporter.preflight(fileURL: url)
        let plan = try BackupImporter.plan(preflight, container: destination)
        var tally = ImportTally()
        for try await batch in BackupImporter.batches(for: plan) {
            #expect(store.importThoughts(batch.thoughts, tags: preflight.tags, tally: &tally))
        }
        return (plan, tally)
    }

    func count<Model: PersistentModel>(_ type: Model.Type, in container: ModelContainer) throws -> Int {
        try container.mainContext.fetchCount(FetchDescriptor<Model>())
    }

    func thought(_ id: UUID, in container: ModelContainer) throws -> Thought? {
        try container.mainContext.fetch(FetchDescriptor<Thought>(predicate: #Predicate { $0.id == id })).first
    }

    func validManifest(
        entries: [String: String], version: Int = 1, format: String = BackupFormat.identifier, thoughts: Int = 0, tags: Int = 0
    ) throws -> Data {
        try BackupFormat.encoder().encode(BackupManifest(
            format: format, formatVersion: version, appVersion: "1", build: "1", exportedAt: now,
            counts: .init(thoughts: thoughts, tags: tags, images: entries.keys.filter { $0.hasPrefix("images/") }.count),
            entries: entries
        ))
    }

    /// An archive that is valid but for what the test changes: no thoughts, no tags.
    func writeMinimalArchive(
        to url: URL, extra: [ArchiveEntry] = [], version: Int = 1, hashOverride: [String: String] = [:],
        omit: Set<String> = []
    ) throws {
        let tags = Data()
        let thoughts = Data()
        var hashes = [BackupFormat.tagsPath: sha256Hex(tags), BackupFormat.thoughtsPath: sha256Hex(thoughts)]
        for entry in extra { hashes[entry.path] = sha256Hex(entry.data) }
        for (path, hash) in hashOverride { hashes[path] = hash }
        for path in omit { hashes[path] = nil }
        try writeArchive(
            [
                ArchiveEntry(path: "mimetype", data: Data(BackupFormat.mimeType.utf8), method: .none),
                ArchiveEntry(path: "manifest.json", data: try validManifest(entries: hashes, version: version)),
                ArchiveEntry(path: BackupFormat.tagsPath, data: tags, method: .none),
                ArchiveEntry(path: BackupFormat.thoughtsPath, data: thoughts, method: .none),
            ] + extra,
            to: url
        )
    }

    func expectRejected(_ url: URL, _ expected: BackupError, limits: ImportLimits = .standard, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: expected, sourceLocation: sourceLocation) {
            try BackupImporter.preflight(fileURL: url, limits: limits)
        }
    }

    func expectRejectedAsUnsafe(_ url: URL, limits: ImportLimits = .standard, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try BackupImporter.preflight(fileURL: url, limits: limits)
            Issue.record("Expected rejection", sourceLocation: sourceLocation)
        } catch let error as BackupError {
            guard case .unsafe = error else {
                Issue.record("Expected .unsafe, got \(error)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("Unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Image normalization

    private func storedImageSize(_ asset: ImageAsset) throws -> (width: Int, height: Int, hasMetadata: Bool) {
        let data = try #require(asset.data)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            properties[kCGImagePropertyExifDictionary] != nil || properties[kCGImagePropertyGPSDictionary] != nil
        )
    }

    @Test func importedImagesAreResizedStrippedAndMeasured() async throws {
        let png = makeTestImageData(width: 3000, height: 1500, type: .png)
        let exif = makeTestImageData(
            width: 300, height: 200,
            properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"],
                         kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.5]]
        )
        let wrongSize = ImageRecord(id: UUID(), width: 10, height: 10, order: 0)
        let withExif = ImageRecord(id: UUID(), width: 300, height: 200, order: 1)
        let id = UUID()
        let rec = record(
            id: id, body: "# Pics\n\(ImageToken.token(for: wrongSize.id))\n\(ImageToken.token(for: withExif.id))",
            images: [wrongSize, withExif]
        )
        let images = [BackupFormat.imagePath(for: wrongSize.id): png, BackupFormat.imagePath(for: withExif.id): exif]
        let thoughts = try BackupFormat.encoder().encode(rec) + Data("\n".utf8)
        var hashes = [BackupFormat.tagsPath: sha256Hex(Data()), BackupFormat.thoughtsPath: sha256Hex(thoughts)]
        for (path, data) in images { hashes[path] = sha256Hex(data) }
        let url = directory.appendingPathComponent("foreign.thoughtreps")
        try writeArchive(
            [
                ArchiveEntry(path: "mimetype", data: Data(BackupFormat.mimeType.utf8), method: .none),
                ArchiveEntry(path: "manifest.json", data: try validManifest(entries: hashes, thoughts: 1)),
                ArchiveEntry(path: BackupFormat.tagsPath, data: Data(), method: .none),
                ArchiveEntry(path: BackupFormat.thoughtsPath, data: thoughts, method: .none),
            ] + images.map { ArchiveEntry(path: $0.key, data: $0.value) },
            to: url
        )

        try await importFile(url)

        let stored = try #require(try thought(id, in: destination))
        let big = try #require(stored.images?.first { $0.id == wrongSize.id })
        let size = try storedImageSize(big)
        #expect(size.width == 2048 && size.height == 1024)
        #expect(big.width == 2048 && big.height == 1024)
        let small = try #require(stored.images?.first { $0.id == withExif.id })
        let smallSize = try storedImageSize(small)
        #expect(smallSize.width == 300 && smallSize.height == 200 && !smallSize.hasMetadata)
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
    }

    @Test func importableKeepsAppProcessedImagesByteForByte() throws {
        let processed = try #require(try realImage(0.3).processed)
        let result = try ImageProcessor.importable(processed.data)
        #expect(result.data == processed.data)
        #expect(result.width == processed.width && result.height == processed.height)
    }

    @Test func importableKeepsACleanJPEGLikeTheFallbackEncoderWritesByteForByte() throws {
        let jpeg = makeTestImageData(
            width: 300, height: 200, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: ImageProcessor.quality]
        )
        let result = try ImageProcessor.importable(jpeg)
        #expect(result.data == jpeg)
        #expect(result.width == 300 && result.height == 200)
    }

    @Test func importableRejectsUndecodableBytes() {
        #expect(throws: ImageProcessingError.undecodable) { try ImageProcessor.importable(Data("nope".utf8)) }
    }

    // MARK: Round trip

    @Test func roundTripReproducesTheStore() async throws {
        try populate()
        let first = try export(from: source)
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        #expect(first.lastPathComponent.hasPrefix("ThoughtReps-export-") && first.pathExtension == "thoughtreps")
        #expect(try BackupImporter.hasSignature(first))

        let (plan, tally) = try await importFile(first)
        #expect(plan.new == 3 && plan.newer == 0 && plan.upToDate == 0)
        #expect(plan.imageCount == 3 && plan.thoughtCount == 3)
        #expect(tally.added == 3)
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
        #expect(try count(Thought.self, in: destination) == 3)
        #expect(try count(ImageAsset.self, in: destination) == 3)
        #expect(try count(Block.self, in: destination) == 2)
        #expect(try count(ThoughtReps.Tag.self, in: destination) == 3)

        let second = try export(from: destination)
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        let before = try BackupImporter.preflight(fileURL: first).manifest
        let after = try BackupImporter.preflight(fileURL: second).manifest
        #expect(before.entries == after.entries)
        #expect(before.counts == after.counts)
        #expect(before.format == "com.thoughtreps.export" && before.formatVersion == 1)
        #expect(before.appVersion == "1.0" && before.build == "7")

        let work = try #require(try destination.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>(predicate: #Predicate { $0.name == "work" })).first)
        #expect(work.colorHex == "#FF8800" && work.displayName == "Work")
        for image in try destination.mainContext.fetch(FetchDescriptor<ImageAsset>()) {
            #expect(image.thumbnailData?.isEmpty == false)
        }
    }

    @Test func learnModeRoundTripsAndOldRecordsDecodeWithoutIt() async throws {
        let learner = sourceStore.create(body: "# Learner", learn: true, now: now)
        let day1 = Scheduler.adding(days: 1, to: now, calendar: .current)
        sourceStore.review(learner, gotIt: true, now: day1)
        sourceStore.review(learner, gotIt: true, now: Scheduler.adding(days: 7, to: day1, calendar: .current))
        #expect(learner.learnIntervalDays == 12)
        let file = try export(from: source)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try await importFile(file)
        let copy = try #require(try thought(learner.id, in: destination))
        #expect(copy.intervalMode == .learn && copy.learnIntervalDays == 12)
        #expect(copy.nextDueAt == learner.nextDueAt)
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)

        var json = try JSONSerialization.jsonObject(with: BackupFormat.encoder().encode(record())) as! [String: Any]
        json["learnIntervalDays"] = nil
        let decoded = try BackupFormat.decoder().decode(ThoughtRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.learnIntervalDays == nil)
    }

    @Test func learnIntervalMustMatchModeAndRange() {
        var learn = record()
        learn.intervalModeRaw = IntervalMode.learn.rawValue
        #expect(learn.isImportable)
        learn.learnIntervalDays = 12
        #expect(learn.isImportable)
        learn.learnIntervalDays = 0
        #expect(!learn.isImportable)
        learn.learnIntervalDays = 366
        #expect(!learn.isImportable)
        var fixed = record()
        fixed.learnIntervalDays = 5
        #expect(!fixed.isImportable)
    }

    @Test func importNormalizesTagColors() throws {
        let record = ThoughtRecord(
            id: UUID(), body: "# T\n#a #b #c #d", createdAt: now, updatedAt: now, nextDueAt: now,
            lastViewedAt: nil, viewCount: 0, intervalDays: nil, intervalModeRaw: IntervalMode.fixed.rawValue,
            isPinned: false, isArchived: false, archivedAt: nil, tags: [], blocks: [], images: []
        )
        let info = [
            TagRecord(name: "a", displayName: "a", colorHex: "#ff8800"),
            TagRecord(name: "b", displayName: "b", colorHex: "3352d1"),
            TagRecord(name: "c", displayName: "c", colorHex: "red"),
            TagRecord(name: "d", displayName: "d", colorHex: nil),
        ]
        var tally = ImportTally()
        #expect(destinationStore.importThoughts([ImportedThought(record: record, images: [:])], tags: info, tally: &tally))
        let tags = try destination.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>())
        let colors = Dictionary(uniqueKeysWithValues: tags.map { ($0.name, $0.colorHex) })
        #expect(colors["a"] == "#FF8800")
        #expect(colors["b"] == "#3352D1")
        #expect(colors["c"] == .some(nil))
        #expect(colors["d"] == .some(nil))
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
    }

    @Test func reimportingTheSameFileChangesNothing() async throws {
        try populate()
        let file = try export(from: source)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try await importFile(file)
        let (plan, tally) = try await importFile(file)
        #expect(plan.new == 0 && plan.newer == 0 && plan.upToDate == 3)
        #expect(tally == ImportTally())
        #expect(try count(Thought.self, in: destination) == 3)
        #expect(try count(ImageAsset.self, in: destination) == 3)
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
    }

    @Test func importingIntoTheSourceStoreChangesNothing() async throws {
        try populate()
        let file = try export(from: source)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preflight = try BackupImporter.preflight(fileURL: file)
        let plan = try BackupImporter.plan(preflight, container: source)
        #expect(plan.toImport.isEmpty && plan.upToDate == 3)
    }

    // MARK: Merge

    @Test func newerReplacesOlderIsSkippedAndTagsMatchByName() async throws {
        let inline = try realImage(0.3)
        let a = sourceStore.create(
            body: "# A\n\(ImageToken.token(for: inline.id))\n#swift", blocks: [BlockDraft(content: "old block")], images: [inline], now: now
        )
        sourceStore.create(body: "# B\n#swift", now: now)
        let c = sourceStore.create(body: "# C", now: now)
        let first = try export(from: source)
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }

        let local = destinationStore.create(body: "# Local\n#Swift", now: now)
        try await importFile(first)
        #expect(try count(ThoughtReps.Tag.self, in: destination) == 1)
        let swift = try #require(try destination.mainContext.fetch(FetchDescriptor<ThoughtReps.Tag>()).first)
        #expect(swift.displayName == "Swift")

        let later = now.addingTimeInterval(1000)
        let gallery = BlockDraft(kind: .gallery, title: "New", images: [try realImage(0.7)])
        sourceStore.update(a, body: "# A v2\n#swift #fresh", blocks: [gallery], intervalDays: nil, now: later)
        // The destination edits C after the source did, so its copy is the newer one.
        sourceStore.update(c, body: "# C source", blocks: [], intervalDays: nil, now: later)
        let destinationC = try #require(try thought(c.id, in: destination))
        destinationStore.update(destinationC, body: "# C destination", blocks: [], intervalDays: nil, now: later.addingTimeInterval(1))
        let second = try export(from: source)
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }

        let (plan, tally) = try await importFile(second)
        #expect(plan.newer == 1 && plan.new == 0 && plan.upToDate == 2)
        #expect(tally.replaced == 1 && tally.added == 0)
        let importedA = try #require(try thought(a.id, in: destination))
        #expect(importedA.body == "# A v2\n#swift #fresh")
        #expect(importedA.updatedAt == later)
        #expect(importedA.images?.count == 1 && importedA.images?.first?.block != nil)
        #expect(importedA.sortedBlocks.map(\.kind) == [.gallery])
        #expect(importedA.sortedTags.map(\.name) == ["fresh", "swift"])
        #expect(try thought(c.id, in: destination)?.body == "# C destination")
        #expect(try thought(local.id, in: destination)?.body == "# Local\n#Swift")
        #expect(try count(ThoughtReps.Tag.self, in: destination) == 2)
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
    }

    @Test func failedBatchSaveLeavesNothingAndImportingAgainFinishes() async throws {
        try populate()
        let file = try export(from: source)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var failing = destinationStore
        failing.save = { _ in throw InjectedSaveFailure() }
        let preflight = try BackupImporter.preflight(fileURL: file)
        let plan = try BackupImporter.plan(preflight, container: destination)
        var tally = ImportTally()
        for try await batch in BackupImporter.batches(for: plan) {
            #expect(!failing.importThoughts(batch.thoughts, tags: preflight.tags, tally: &tally))
        }
        #expect(tally.added == 0)
        #expect(try count(Thought.self, in: destination) == 0)
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)

        let (_, finished) = try await importFile(file)
        #expect(finished.added == 3)
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
    }

    // MARK: Rejection

    @Test func zipRenamedExportIsAccepted() throws {
        try populate()
        let file = try export(from: source)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let renamed = directory.appendingPathComponent("backup.zip")
        try FileManager.default.copyItem(at: file, to: renamed)
        #expect(try BackupImporter.preflight(fileURL: renamed).manifest.counts.thoughts == 3)
    }

    @Test func otherFilesAreNotExports() throws {
        let text = directory.appendingPathComponent("note.thoughtreps")
        try Data("hello".utf8).write(to: text)
        expectRejected(text, .notAnExport)

        let plainZip = directory.appendingPathComponent("plain.zip")
        try writeArchive([ArchiveEntry(path: "readme.txt", data: Data("hi".utf8))], to: plainZip)
        expectRejected(plainZip, .notAnExport)

        let epub = directory.appendingPathComponent("book.zip")
        try writeArchive([ArchiveEntry(path: "mimetype", data: Data("application/epub+zip".utf8), method: .none)], to: epub)
        expectRejected(epub, .notAnExport)

        let compressedSignature = directory.appendingPathComponent("compressed.zip")
        try writeArchive([ArchiveEntry(path: "mimetype", data: Data(BackupFormat.mimeType.utf8), method: .deflate)], to: compressedSignature)
        expectRejected(compressedSignature, .notAnExport)

        let wrongFormat = directory.appendingPathComponent("other-format.zip")
        try writeArchive(
            [
                ArchiveEntry(path: "mimetype", data: Data(BackupFormat.mimeType.utf8), method: .none),
                ArchiveEntry(path: "manifest.json", data: try validManifest(entries: [:], format: "com.example.other")),
            ],
            to: wrongFormat
        )
        expectRejected(wrongFormat, .notAnExport)
    }

    @Test func newerFormatVersionAsksForAnUpdate() throws {
        let url = directory.appendingPathComponent("future.thoughtreps")
        try writeMinimalArchive(to: url, version: 2)
        expectRejected(url, .needsNewerApp)
        #expect(BackupError.needsNewerApp.errorDescription == "Update Thought Reps to import this file.")
        #expect(BackupError.notAnExport.errorDescription == "This isn't a Thought Reps export.")
    }

    @Test func minimalArchiveIsValid() throws {
        let url = directory.appendingPathComponent("minimal.thoughtreps")
        try writeMinimalArchive(to: url)
        #expect(try BackupImporter.preflight(fileURL: url).stamps.isEmpty)
    }

    @Test func hashMismatchIsRejected() throws {
        let url = directory.appendingPathComponent("bad-hash.thoughtreps")
        try writeMinimalArchive(to: url, hashOverride: [BackupFormat.tagsPath: String(repeating: "0", count: 64)])
        expectRejected(url, .damaged("tags.jsonl is corrupt"))
    }

    @Test func manifestMustListEveryEntry() throws {
        let missing = directory.appendingPathComponent("unlisted.thoughtreps")
        try writeMinimalArchive(to: missing, omit: [BackupFormat.tagsPath])
        expectRejected(missing, .damaged("the manifest doesn't match the file's contents"))
    }

    @Test func traversalAndUnknownPathsAreRejected() throws {
        for path in ["../evil", "/etc/passwd", "images/../../evil", "extra.txt", "images/not-a-uuid", "images/\(UUID().uuidString.lowercased())"] {
            let url = directory.appendingPathComponent("path-\(UUID().uuidString).thoughtreps")
            try writeMinimalArchive(to: url, extra: [ArchiveEntry(path: path, data: Data("x".utf8))])
            expectRejectedAsUnsafe(url)
        }
    }

    @Test func oversizedEntriesAreRejectedWhateverTheirCompressedSize() throws {
        let id = UUID()
        let bomb = Data(count: 200_000)
        let url = directory.appendingPathComponent("bomb.thoughtreps")
        try writeMinimalArchive(to: url, extra: [ArchiveEntry(path: BackupFormat.imagePath(for: id), data: bomb)])
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? .max < 100_000)
        var limits = ImportLimits()
        limits.imageBytes = 10_000
        expectRejectedAsUnsafe(url, limits: limits)
    }

    @Test func lineLongerThanTheLimitIsRejected() throws {
        var reader = LineReader(maxLineBytes: 8)
        #expect(throws: BackupError.self) {
            try reader.feed(Data(repeating: 0x41, count: 20)) { _ in }
        }
        var split = LineReader(maxLineBytes: 8)
        var lines: [String] = []
        try split.feed(Data("ab\ncd".utf8)) { lines.append(String(decoding: $0, as: UTF8.self)) }
        try split.feed(Data("ef\n\ngh".utf8)) { lines.append(String(decoding: $0, as: UTF8.self)) }
        try split.finish { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(lines == ["ab", "cdef", "gh"])
    }

    // MARK: Records

    @Test func recordsThatBreakInvariantsAreNotImportable() {
        let image = ImageRecord(id: UUID(), width: 10, height: 10, order: 0)
        #expect(record().isImportable)
        #expect(!record(body: "![](img:\(UUID().uuidString))").isImportable)
        #expect(record(body: ImageToken.token(for: image.id), images: [image]).isImportable)
        #expect(!record(blocks: [BlockRecord(id: UUID(), kindRaw: "gallery", title: nil, content: "", order: 0, images: [])]).isImportable)
        #expect(!record(blocks: [BlockRecord(id: UUID(), kindRaw: "mystery", title: nil, content: "x", order: 0, images: [])]).isImportable)
        #expect(!record(updatedAt: Date(timeIntervalSince1970: 1)).isImportable)
    }

    @Test func batchesAreCutByImageBytesAsWellAsThoughtCount() async throws {
        for hue in [0.1, 0.4, 0.8] {
            let image = try realImage(hue)
            sourceStore.create(body: "# Photo \(hue)\n\(ImageToken.token(for: image.id))", images: [image], now: now.addingTimeInterval(hue * 100))
        }
        sourceStore.create(body: "# Plain", now: now.addingTimeInterval(500))
        let file = try export(from: source)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let plan = try BackupImporter.plan(try BackupImporter.preflight(fileURL: file), container: destination)

        var sizes: [Int] = []
        for try await batch in BackupImporter.batches(for: plan) { sizes.append(batch.thoughts.count) }
        #expect(sizes == [4])

        var limits = ImportLimits()
        limits.batchImageBytes = 1
        sizes = []
        for try await batch in BackupImporter.batches(for: plan, limits: limits) { sizes.append(batch.thoughts.count) }
        #expect(sizes.count == 4 || sizes.count == 3)
        #expect(sizes.reduce(0, +) == 4 && sizes.allSatisfy { $0 <= 2 })
    }

    @Test func exportKeepsEveryThoughtWhenTimestampsRepeat() throws {
        for index in 0..<10 {
            sourceStore.create(body: "# Same time \(index)", now: now)
        }
        var exporter = BackupExporter(container: source, appVersion: "1", build: "1")
        exporter.thoughtBatchSize = 3
        let file = try exporter.export(now: now)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(try BackupImporter.preflight(fileURL: file).stamps.count == 10)
    }

    @Test func deletingAThoughtMidExportDropsNoOtherThought() throws {
        var ids: [UUID] = []
        for index in 0..<9 {
            ids.append(sourceStore.create(body: "# T\(index)", now: now.addingTimeInterval(Double(index))).id)
        }
        var exporter = BackupExporter(container: source, appVersion: "1", build: "1")
        exporter.thoughtBatchSize = 2
        let container = source
        let deleted = ids[0]
        let done = OSAllocatedUnfairLock(initialState: false)
        let file = try exporter.export(now: now) { fraction in
            guard fraction > 0.25, fraction < 0.5, !done.withLock({ let was = $0; $0 = true; return was }) else { return }
            let context = ModelContext(container)
            if let thought = try? context.fetch(FetchDescriptor<Thought>(predicate: #Predicate { $0.id == deleted })).first {
                context.delete(thought)
                try? context.save()
            }
        }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(Set(try BackupImporter.preflight(fileURL: file).stamps.keys) == Set(ids))
        #expect(done.withLock { $0 })
    }

    @Test func inlineImageWithoutBytesIsLeftOutAndItsTokenStripped() async throws {
        let image = try realImage(0.4)
        let created = sourceStore.create(body: "# Pic\n\(ImageToken.token(for: image.id))\ntext", images: [image], now: now)
        try #require(created.images?.first).data = nil
        try source.mainContext.save()
        let file = try export(from: source)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preflight = try BackupImporter.preflight(fileURL: file)
        #expect(preflight.unimportable == 0 && preflight.stamps.count == 1)
        #expect(preflight.manifest.counts.images == 0)
        try await importFile(file)
        #expect(try thought(created.id, in: destination)?.body == "# Pic\n\ntext")
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
    }

    @Test func imageIDsSharedByThoughtsInOneBatchAreRejected() throws {
        let shared = ImageRecord(id: UUID(), width: 10, height: 10, order: 0)
        let processed = fakeImage(1)
        func item(_ body: String) -> ImportedThought {
            ImportedThought(
                record: record(body: "\(body)\n\(ImageToken.token(for: shared.id))", images: [shared]),
                images: [shared.id: processed]
            )
        }
        var tally = ImportTally()
        #expect(destinationStore.importThoughts([item("# A"), item("# B")], tags: [], tally: &tally))
        #expect(tally.added == 1 && tally.rejected == 1)
        #expect(try count(ImageAsset.self, in: destination) == 1)
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
    }

    @Test func replacementBlockIDsClashingWithAnotherThoughtGetFreshOnes() throws {
        let other = destinationStore.create(body: "# Other", blocks: [BlockDraft(content: "x")], now: now)
        let takenID = try #require(other.blocks?.first).id
        let target = destinationStore.create(body: "# Target", now: now)
        let incoming = record(
            id: target.id, body: "# Target v2", createdAt: now, updatedAt: now.addingTimeInterval(10),
            blocks: [BlockRecord(id: takenID, kindRaw: "blurred", title: nil, content: "y", order: 0, images: [])]
        )
        var tally = ImportTally()
        #expect(destinationStore.importThoughts([ImportedThought(record: incoming, images: [:])], tags: [], tally: &tally))
        #expect(tally.replaced == 1)
        #expect(try IntegrityChecker.check(destination.mainContext).isEmpty)
    }

    @Test func onlyOpenInInboxFilesAreDeletedAfterCopying() throws {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #expect(BackupModel.isInOpenInInbox(documents.appendingPathComponent("Inbox/x.thoughtreps")))
        #expect(!BackupModel.isInOpenInInbox(documents.appendingPathComponent("x.thoughtreps")))
        #expect(!BackupModel.isInOpenInInbox(directory.appendingPathComponent("Inbox/x.thoughtreps")))
    }

    @Test func startingAnImportWhileBusyExplainsWhy() {
        let model = BackupModel()
        model.beginImport(from: directory.appendingPathComponent("missing.thoughtreps"), container: destination)
        model.beginImport(from: directory.appendingPathComponent("missing.thoughtreps"), container: destination)
        #expect(model.problem == "Wait for the current export or import to finish.")
    }

    @Test func fileNameUsesTheDate() {
        let name = BackupFormat.fileName(for: now)
        #expect(name.hasPrefix("ThoughtReps-export-20") && name.hasSuffix(".thoughtreps"))
        #expect(name.count == "ThoughtReps-export-2026-10-05.thoughtreps".count)
    }
}
