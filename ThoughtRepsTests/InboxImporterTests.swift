import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import ThoughtReps

@MainActor
@Suite("InboxImporter")
struct InboxImporterTests {
    let container: ModelContainer
    let dir: URL
    let defaults: UserDefaults
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    init() throws {
        container = try ModelContainer(
            for: Thought.self, ThoughtReps.Tag.self, Block.self, ImageAsset.self, Tombstone.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "InboxImporterTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    func store(failingSave: Bool = false) -> ThoughtStore {
        var store = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: SaveErrorCenter())
        if failingSave { store.save = { _ in throw CocoaError(.fileWriteUnknown) } }
        return store
    }

    func importer(removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> InboxImporter {
        InboxImporter(defaults: defaults, removeFile: removeFile)
    }

    var rememberedIDs: [String] { defaults.stringArray(forKey: InboxImporter.importedIDsKey) ?? [] }

    @discardableResult
    func drop(_ body: String, at date: Date) throws -> InboxItem {
        let item = InboxItem(id: UUID(), body: body, createdAt: date)
        try Inbox.write(item, to: dir)
        return item
    }

    func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func thoughts() throws -> [Thought] {
        try container.mainContext.fetch(FetchDescriptor<Thought>(sortBy: [SortDescriptor(\.createdAt)]))
    }

    @Test func importCreatesThoughtsAndDeletesFiles() async throws {
        let created = t0.addingTimeInterval(-3 * 86_400)
        try drop("Hello #swift", at: created)
        let count = await importer().importPending(from: dir, store: store())
        #expect(count == 1)
        let thought = try #require(try thoughts().first)
        #expect(thought.body == "Hello #swift")
        #expect(thought.createdAt == created)
        #expect(thought.nextDueAt == Scheduler.adding(days: 7, to: created, calendar: .current))
        #expect(thought.tags?.map(\.name) == ["swift"])
        #expect(try files().isEmpty)
        #expect(rememberedIDs.isEmpty)
    }

    @Test func unreadableFileIsLeftInPlace() async throws {
        let unreadable = dir.appendingPathComponent("\(UUID().uuidString).json", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try drop("Fine", at: t0)
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        #expect(try files() == [unreadable.lastPathComponent])
    }

    @Test func undecodableFileIsDeleted() async throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
        #expect(await importer().importPending(from: dir, store: store()) == 0)
        #expect(try files().isEmpty)
    }

    @Test func failedSaveKeepsFile() async throws {
        try drop("Keep me", at: t0)
        let failing = store(failingSave: true)
        let count = await importer().importPending(from: dir, store: failing)
        #expect(count == 0)
        #expect(failing.saveErrors.message?.contains("Couldn't import a shared thought.") == true)
        #expect(failing.saveErrors.note == nil)
        #expect(try files().count == 1)
        #expect(try thoughts().isEmpty)
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        #expect(try files().isEmpty)
    }

    @Test func failedCreateStopsTheRunAndKeepsLaterFiles() async throws {
        try drop("first", at: t0)
        try drop("second", at: t0.addingTimeInterval(1))
        try drop("third", at: t0.addingTimeInterval(2))
        var calls = 0
        var flaky = store()
        flaky.save = { context in
            calls += 1
            if calls == 2 { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }
        #expect(await importer().importPending(from: dir, store: flaky) == 1)
        #expect(calls == 2)
        #expect(try thoughts().map(\.body) == ["first"])
        #expect(try files().count == 2)

        #expect(await importer().importPending(from: dir, store: store()) == 2)
        #expect(try thoughts().map(\.body) == ["first", "second", "third"])
        #expect(try files().isEmpty)
    }

    @Test func failedDeleteDoesNotDuplicateOnNextRun() async throws {
        let item = try drop("Once", at: t0)
        let stuck = importer(removeFile: { _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(await stuck.importPending(from: dir, store: store()) == 1)
        #expect(try files().count == 1)
        #expect(rememberedIDs == [item.id.uuidString])

        #expect(await importer().importPending(from: dir, store: store()) == 0)
        #expect(try thoughts().count == 1)
        #expect(try files().isEmpty)
        #expect(rememberedIDs.isEmpty)
    }

    @Test func rememberedIDsWithoutFilesArePruned() async throws {
        defaults.set([UUID().uuidString], forKey: InboxImporter.importedIDsKey)
        await importer().importPending(from: dir, store: store())
        #expect(rememberedIDs.isEmpty)
    }

    @Test func corruptJSONIsDeletedAndOthersIgnored() async throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("bad.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("note.txt"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("x.tmp"))
        try drop("Good", at: t0)
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        #expect(try thoughts().count == 1)
        #expect(try files() == ["note.txt", "x.tmp"])
    }

    @Test func importsOldestFirst() async throws {
        try drop("second", at: t0.addingTimeInterval(10))
        try drop("third", at: t0.addingTimeInterval(20))
        try drop("first", at: t0)
        #expect(await recordedOrder() == ["first", "second", "third"])
    }

    @Test func importsMillisecondsApartInOrder() async throws {
        try drop("b", at: t0.addingTimeInterval(0.010))
        try drop("a", at: t0)
        try drop("c", at: t0.addingTimeInterval(0.020))
        #expect(await recordedOrder() == ["a", "b", "c"])
    }

    func recordedOrder() async -> [String] {
        var order: [String] = []
        var recording = store()
        recording.save = { context in
            order.append(contentsOf: context.insertedModelsArray.compactMap { ($0 as? Thought)?.body })
            try context.save()
        }
        await importer().importPending(from: dir, store: recording)
        return order
    }

    @Test func missingDirectoryImportsNothing() async {
        let missing = dir.appendingPathComponent("nope")
        #expect(await importer().importPending(from: missing, store: store()) == 0)
    }

    @Test func itemRoundTripsWithMilliseconds() async throws {
        let item = InboxItem(id: UUID(), body: "Body\nwith #tag", createdAt: t0.addingTimeInterval(0.123))
        let data = try InboxItem.encoder().encode(item)
        let decoded = try InboxItem.decoder().decode(InboxItem.self, from: data)
        #expect(decoded.id == item.id)
        #expect(decoded.body == item.body)
        #expect(abs(decoded.createdAt.timeIntervalSince(item.createdAt)) < 0.0005)
    }

    @Test func writeLeavesNoTempFile() async throws {
        let item = try drop("x", at: t0)
        #expect(try files() == ["\(item.id.uuidString).json"])
    }

    @Test func directoryURLThrowsWithoutGroupKey() {
        #expect(throws: Inbox.InboxError.self) {
            try Inbox.directoryURL(bundle: Bundle(for: BundleToken.self))
        }
    }

    @discardableResult
    func dropAttachment(
        body: String, data: Data, filename: String, type: UTType, at date: Date, stored: Bool = true
    ) throws -> InboxItem {
        let id = UUID()
        if stored { try data.write(to: dir.appendingPathComponent(Inbox.attachmentPath(for: id))) }
        let item = InboxItem(
            id: id, body: body, createdAt: date,
            attachment: .init(filename: filename, typeIdentifier: type.identifier, path: Inbox.attachmentPath(for: id))
        )
        try Inbox.write(item, to: dir)
        return item
    }

    @Test func sharedFileBecomesAFileBlock() async throws {
        let bytes = Data("%PDF-1.4 fake".utf8)
        try dropAttachment(body: "Read this", data: bytes, filename: "paper.pdf", type: .pdf, at: t0)
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        let thought = try #require(try thoughts().first)
        #expect(thought.body == "Read this")
        let block = try #require(thought.sortedBlocks.first)
        #expect(block.kind == .file)
        #expect(block.file?.filename == "paper.pdf")
        #expect(block.file?.typeIdentifier == UTType.pdf.identifier)
        #expect(block.file?.data == bytes)
        #expect(try files().isEmpty)
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test func sharedImageBecomesAGalleryThroughImageProcessing() async throws {
        let photo = makeTestImageData(width: 3000, height: 1500, type: .jpeg)
        try dropAttachment(body: "Look", data: photo, filename: "IMG_1.JPG", type: .jpeg, at: t0)
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        let thought = try #require(try thoughts().first)
        let block = try #require(thought.sortedBlocks.first)
        #expect(block.kind == .gallery)
        let image = try #require(block.sortedImages.first)
        #expect(image.width == ImageProcessor.maxDimension)
        #expect(image.thumbnailData != nil)
        #expect(block.file == nil)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<FileAsset>()) == 0)
        #expect(try files().isEmpty)
        #expect(try IntegrityChecker.check(container.mainContext).isEmpty)
    }

    @Test func imageThatCannotBeDecodedFallsBackToAFileBlock() async throws {
        try dropAttachment(body: "Odd", data: Data("not an image".utf8), filename: "odd.png", type: .png, at: t0)
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        let block = try #require(try thoughts().first?.sortedBlocks.first)
        #expect(block.kind == .file)
        #expect(block.file?.filename == "odd.png")
    }

    @Test func attachmentOverTheCapIsLeftOut() async throws {
        try dropAttachment(body: "Big", data: Data(count: FileAttachment.maxBytes + 1), filename: "big.bin", type: .data, at: t0)
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        let thought = try #require(try thoughts().first)
        #expect(thought.blocks?.isEmpty == true)
        #expect(try files().isEmpty)
    }

    @Test func missingAttachmentStillImportsTheText() async throws {
        try dropAttachment(body: "Text survives", data: Data(), filename: "gone.pdf", type: .pdf, at: t0, stored: false)
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        let thought = try #require(try thoughts().first)
        #expect(thought.body == "Text survives")
        #expect(thought.blocks?.isEmpty == true)
    }

    @Test func attachmentPathsOutsideTheInboxAreIgnored() async throws {
        let outside = dir.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let item = InboxItem(
            id: UUID(), body: "Sneaky", createdAt: t0,
            attachment: .init(filename: "x.txt", typeIdentifier: UTType.plainText.identifier, path: "../\(outside.lastPathComponent)")
        )
        try Inbox.write(item, to: dir)
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        #expect(try thoughts().first?.blocks?.isEmpty == true)
    }

    @Test func failedCreateKeepsTheAttachment() async throws {
        let item = try dropAttachment(body: "Keep", data: Data("x".utf8), filename: "a.txt", type: .plainText, at: t0)
        #expect(await importer().importPending(from: dir, store: store(failingSave: true)) == 0)
        #expect(try files().sorted() == [Inbox.attachmentPath(for: item.id), "\(item.id.uuidString).json"].sorted())
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        #expect(try files().isEmpty)
    }

    @Test func orphanAttachmentsAreDeletedOnTheSecondRun() async throws {
        let orphan = dir.appendingPathComponent(Inbox.attachmentPath(for: UUID()))
        try Data("x".utf8).write(to: orphan)
        try dropAttachment(body: "Ready", data: Data("z".utf8), filename: "c.txt", type: .plainText, at: t0)

        #expect(await importer().importPending(from: dir, store: store()) == 1)
        #expect(FileManager.default.fileExists(atPath: orphan.path))

        #expect(await importer().importPending(from: dir, store: store()) == 0)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try files().isEmpty)
    }

    @Test func attachmentSurvivesWhenItsItemShowsUpBetweenRuns() async throws {
        let id = UUID()
        let early = dir.appendingPathComponent(Inbox.attachmentPath(for: id))
        try Data("x".utf8).write(to: early)
        #expect(await importer().importPending(from: dir, store: store()) == 0)
        let item = InboxItem(
            id: id, body: "Late", createdAt: t0,
            attachment: .init(filename: "late.txt", typeIdentifier: UTType.plainText.identifier, path: Inbox.attachmentPath(for: id))
        )
        try Inbox.write(item, to: dir)
        #expect(await importer().importPending(from: dir, store: store()) == 1)
        #expect(try thoughts().first?.sortedBlocks.first?.file?.filename == "late.txt")
    }

    @Test func saveErrorNoteIsOnlySetAroundTheCreate() async throws {
        try dropAttachment(body: "Slow", data: Data("x".utf8), filename: "a.txt", type: .plainText, at: t0)
        let center = SaveErrorCenter()
        var watched = ThoughtStore(context: container.mainContext, defaultIntervalDays: 7, saveErrors: center)
        var noteAtSave: String?
        watched.save = { context in
            noteAtSave = center.note
            try context.save()
        }
        let importer = importer()
        let run = Task { await importer.importPending(from: dir, store: watched) }
        await Task.yield()
        #expect(center.note == nil)
        #expect(await run.value == 1)
        #expect(noteAtSave == "Couldn't import a shared thought.")
        #expect(center.note == nil)
    }

    @Test func importStartedDuringARunIsPickedUpByIt() async throws {
        try dropAttachment(body: "first", data: Data("x".utf8), filename: "a.txt", type: .plainText, at: t0)
        let importer = importer()
        let store = store()
        let run = Task { await importer.importPending(from: dir, store: store) }
        await Task.yield()
        try dropAttachment(body: "second", data: Data("y".utf8), filename: "b.txt", type: .plainText, at: t0.addingTimeInterval(1))
        #expect(await importer.importPending(from: dir, store: store) == 0)
        #expect(await run.value == 2)
        #expect(try thoughts().map(\.body) == ["first", "second"])
        #expect(try files().isEmpty)
    }

    @Test func undecodableImageOverTheCapIsRefused() throws {
        let junk = dir.appendingPathComponent("big.svg")
        try Data(count: FileAttachment.maxBytes + 1).write(to: junk)
        #expect(SharedContent.exceedsFileCap(type: .svg, at: junk, size: FileAttachment.maxBytes + 1))
        #expect(!SharedContent.exceedsFileCap(type: .svg, at: junk, size: FileAttachment.maxBytes))

        let photo = dir.appendingPathComponent("photo.jpg")
        try makeTestImageData(width: 200, height: 100, type: .jpeg).write(to: photo)
        #expect(SharedContent.isDecodableImage(type: .jpeg, at: photo))
        #expect(!SharedContent.exceedsFileCap(type: .jpeg, at: photo, size: FileAttachment.maxBytes * 4))
        #expect(!SharedContent.isDecodableImage(type: .pdf, at: photo))
    }

    @Test func itemsFromBeforeAttachmentsStillDecode() throws {
        let json = Data(#"{"id":"\#(UUID().uuidString)","body":"Old","createdAt":1790000000000}"#.utf8)
        let item = try InboxItem.decoder().decode(InboxItem.self, from: json)
        #expect(item.attachment == nil)
        #expect(item.body == "Old")
    }

    @Test func attachmentRoundTripsThroughJSON() throws {
        let item = InboxItem(
            id: UUID(), body: "b", createdAt: t0,
            attachment: .init(filename: "f.pdf", typeIdentifier: "com.adobe.pdf", path: "x.attachment")
        )
        let decoded = try InboxItem.decoder().decode(InboxItem.self, from: try InboxItem.encoder().encode(item))
        #expect(decoded.attachment == item.attachment)
    }

    @Test func copyingAnAttachmentLeavesTheSourceAndReplacesAStaleCopy() throws {
        let source = dir.appendingPathComponent("source.bin")
        try Data("abc".utf8).write(to: source)
        let id = UUID()
        let path = try Inbox.copyAttachment(from: source, id: id, to: dir)
        #expect(path == "\(id.uuidString).attachment")
        _ = try Inbox.copyAttachment(from: source, id: id, to: dir)
        #expect(try Data(contentsOf: dir.appendingPathComponent(path)) == Data("abc".utf8))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func classifiesAttachmentProviders() {
        #expect(SharedContent.attachmentType(in: ["com.adobe.pdf", "public.file-url"]) == .pdf)
        #expect(SharedContent.attachmentType(in: ["public.jpeg", "public.image"])?.conforms(to: .image) == true)
        #expect(SharedContent.attachmentType(in: ["public.file-url"]) == .item)
        #expect(SharedContent.attachmentType(in: ["public.plain-text"]) == nil)
        #expect(SharedContent.attachmentType(in: ["net.daringfireball.markdown", "public.file-url"]) == nil)
        #expect(SharedContent.attachmentType(in: ["public.url"]) == nil)
        #expect(SharedContent.attachmentType(in: ["com.apple.property-list"]) == nil)
        #expect(SharedContent.isImage(typeIdentifier: "public.heic"))
        #expect(!SharedContent.isImage(typeIdentifier: "com.adobe.pdf"))
    }

    @Test func mergesTextAndURL() async throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(SharedContent.merge(text: "Note", url: url) == "Note\nhttps://example.com/a")
        #expect(SharedContent.merge(text: "See https://example.com/a", url: url) == "See https://example.com/a")
        #expect(SharedContent.merge(text: nil, url: url) == "https://example.com/a")
        #expect(SharedContent.merge(text: "  Just text \n", url: nil) == "Just text")
        #expect(SharedContent.merge(text: nil, url: nil) == "")
    }
}

private final class BundleToken {}
